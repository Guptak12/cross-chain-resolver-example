// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "solidity-utils/contracts/libraries/SafeERC20.sol";
import { AddressLib, Address } from "solidity-utils/contracts/libraries/AddressLib.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { BaseEscrowFactory } from "../lib/cross-chain-swap/contracts/BaseEscrowFactory.sol";
import { EscrowDst } from "../lib/cross-chain-swap/contracts/EscrowDst.sol";
import { EscrowSrc } from "../lib/cross-chain-swap/contracts/EscrowSrc.sol";
import { MerkleStorageInvalidator } from "../lib/cross-chain-swap/contracts/MerkleStorageInvalidator.sol";
import { SimpleSettlement } from "limit-order-settlement/contracts/SimpleSettlement.sol";
import {IBaseEscrow} from "../lib/cross-chain-swap/contracts/interfaces/IBaseEscrow.sol";
import {TimelocksLib, Timelocks} from "../lib/cross-chain-swap/contracts/libraries/TimelocksLib.sol";
import { ImmutablesLib } from "../lib/cross-chain-swap/contracts/libraries/ImmutablesLib.sol";
import { ProxyHashLib } from "../lib/cross-chain-swap/contracts/libraries/ProxyHashLib.sol";

/**
 * @title ETH-SUI Cross-Chain Escrow Factory
 * @notice Specialized factory for ETH-SUI bidirectional atomic swaps
 * @dev Extends BaseEscrowFactory with SUI-specific functionality
 */
contract EthSuiEscrowFactory is BaseEscrowFactory {
    using AddressLib for Address;
    using SafeERC20 for IERC20;
    using TimelocksLib for Timelocks;
    using ImmutablesLib for IBaseEscrow.Immutables;

    // Sui blockchain identifier
    uint256 public constant SUI_CHAIN_ID = 101;
    
    
    struct SuiSwapTimelocks {
        uint32 ethWithdrawal;      // 1 hour - ETH side withdrawal period
        uint32 ethPublicWithdrawal; // 2 hours - ETH public withdrawal
        uint32 ethCancellation;     // 24 hours - ETH cancellation starts
        uint32 ethPublicCancellation; // 48 hours - ETH public cancellation
        uint32 suiWithdrawal;      // 30 minutes - SUI withdrawal (earlier than ETH)
        uint32 suiPublicWithdrawal; // 1.5 hours - SUI public withdrawal
        uint32 suiCancellation;     // 25 hours - SUI cancellation (after ETH withdrawal)
    }

    // Default timelock values optimized for ETH-SUI cross-chain finality
    uint32 public constant DEFAULT_ETH_WITHDRAWAL = 3600;        // 1 hour
    uint32 public constant DEFAULT_ETH_PUBLIC_WITHDRAWAL = 7200;  // 2 hours  
    uint32 public constant DEFAULT_ETH_CANCELLATION = 86400;     // 24 hours
    uint32 public constant DEFAULT_ETH_PUBLIC_CANCELLATION = 172800; // 48 hours
    uint32 public constant DEFAULT_SUI_WITHDRAWAL = 1800;        // 30 minutes
    uint32 public constant DEFAULT_SUI_PUBLIC_WITHDRAWAL = 5400;  // 1.5 hours
    uint32 public constant DEFAULT_SUI_CANCELLATION = 90000;      // 25 hours

    /**
     * @notice Returns default SUI timelock configuration
     */
    function getDefaultSuiTimelocks() public pure returns (SuiSwapTimelocks memory) {
        return SuiSwapTimelocks({
            ethWithdrawal: DEFAULT_ETH_WITHDRAWAL,
            ethPublicWithdrawal: DEFAULT_ETH_PUBLIC_WITHDRAWAL,
            ethCancellation: DEFAULT_ETH_CANCELLATION,
            ethPublicCancellation: DEFAULT_ETH_PUBLIC_CANCELLATION,
            suiWithdrawal: DEFAULT_SUI_WITHDRAWAL,
            suiPublicWithdrawal: DEFAULT_SUI_PUBLIC_WITHDRAWAL,
            suiCancellation: DEFAULT_SUI_CANCELLATION
        });
    }

    // Cross-chain swap state tracking
    mapping(bytes32 => SuiSwapData) public suiSwaps;
    
    struct SuiSwapData {
        bool isActive;
        uint256 suiAmount;
        bytes32 suiTxHash;
        bytes32 suiTokenAddress; // Represented as 32-byte address for compatibility
        uint64 suiEscrowObjectId; // Sui object ID for the escrow
        uint256 createdAt;
    }

    // Events for cross-chain coordination
    event EthToSuiSwapInitiated(
        bytes32 indexed orderHash,
        bytes32 indexed hashlock,
        address indexed maker,
        address taker,
        uint256 ethAmount,
        uint256 suiAmount,
        bytes32 suiTokenAddress
    );

    event SuiToEthSwapInitiated(
        bytes32 indexed orderHash,
        bytes32 indexed hashlock,
        address indexed taker,
        address maker,
        uint256 suiAmount,
        uint256 ethAmount,
        uint64 suiEscrowObjectId
    );

    event CrossChainSecretRevealed(
        bytes32 indexed orderHash,
        bytes32 secret,
        uint256 chainId
    );

    error InvalidSuiChainId();
    error InvalidSuiTokenAddress();
    error SwapAlreadyExists();
    error SwapNotFound();
    error InvalidTimelock();

    constructor(
        address limitOrderProtocol,
        IERC20 accessToken,
        address owner,
        uint32 rescueDelaySrc,
        uint32 rescueDelayDst
    )
    SimpleSettlement(limitOrderProtocol, accessToken, address(0), owner)
    MerkleStorageInvalidator(limitOrderProtocol) {
        ESCROW_SRC_IMPLEMENTATION = address(new EscrowSrc(rescueDelaySrc, accessToken));
        ESCROW_DST_IMPLEMENTATION = address(new EscrowDst(rescueDelayDst, accessToken));
        _PROXY_SRC_BYTECODE_HASH = ProxyHashLib.computeProxyBytecodeHash(ESCROW_SRC_IMPLEMENTATION);
        _PROXY_DST_BYTECODE_HASH = ProxyHashLib.computeProxyBytecodeHash(ESCROW_DST_IMPLEMENTATION);
    }

    /**
     * @notice Creates ETH escrow for ETH → SUI swap
     * @dev Called via LOP postInteraction, extends base functionality
     */
    function createEthToSuiEscrow(
        IBaseEscrow.Immutables calldata ethImmutables,
        uint256 suiAmount,
        bytes32 suiTokenAddress,
        SuiSwapTimelocks calldata customTimelocks
    ) external payable {
        bytes32 orderHash = ethImmutables.orderHash;
        
        if (suiSwaps[orderHash].isActive) revert SwapAlreadyExists();
        
        // Validate timelock sequencing for cross-chain safety
        _validateSuiTimelocks(customTimelocks);
        
        // Create ETH escrow using parent functionality
        // Note: This would typically be called through the LOP postInteraction
        _createSrcEscrowWithTimelocks(ethImmutables, customTimelocks);
        
        // Store SUI swap data for coordination
        suiSwaps[orderHash] = SuiSwapData({
            isActive: true,
            suiAmount: suiAmount,
            suiTxHash: bytes32(0), // Will be set when SUI escrow is created
            suiTokenAddress: suiTokenAddress,
            suiEscrowObjectId: 0, // Will be set when SUI escrow is created
            createdAt: block.timestamp
        });

        emit EthToSuiSwapInitiated(
            orderHash,
            ethImmutables.hashlock,
            ethImmutables.maker.get(),
            ethImmutables.taker.get(),
            ethImmutables.amount,
            suiAmount,
            suiTokenAddress
        );
    }

    /**
     * @notice Creates ETH escrow for SUI → ETH swap (destination side)
     * @dev Called by relayer after SUI escrow is confirmed
     */
    // function createSuiToEthEscrow(
    //     IBaseEscrow.Immutables calldata ethImmutables,
    //     uint256 srcCancellationTimestamp,
    //     uint64 suiEscrowObjectId,
    //     bytes32 suiTxHash
    // ) external payable {
    //     bytes32 orderHash = ethImmutables.orderHash;
        
    //     // Create ETH destination escrow
    //     createDstEscrow(ethImmutables, srcCancellationTimestamp);
        
    //     // Store cross-chain reference data
    //     suiSwaps[orderHash] = SuiSwapData({
    //         isActive: true,
    //         suiAmount: 0, // Not needed for SUI → ETH
    //         suiTxHash: suiTxHash,
    //         suiTokenAddress: bytes32(0), // Not needed for SUI → ETH
    //         suiEscrowObjectId: suiEscrowObjectId,
    //         createdAt: block.timestamp
    //     });

    //     emit SuiToEthSwapInitiated(
    //         orderHash,
    //         ethImmutables.hashlock,
    //         ethImmutables.taker.get(),
    //         ethImmutables.maker.get(),
    //         0, // SUI amount not tracked here
    //         ethImmutables.amount,
    //         suiEscrowObjectId
    //     );
    // }

    /**
     * @notice Records secret revelation for cross-chain coordination
     * @dev Called when secret is revealed on either chain
     */
    function recordSecretReveal(
        bytes32 orderHash,
        bytes32 secret,
        uint256 revealChainId
    ) external {
        if (!suiSwaps[orderHash].isActive) revert SwapNotFound();
        
        emit CrossChainSecretRevealed(orderHash, secret, revealChainId);
    }

    /**
     * @notice Gets SUI swap data for off-chain coordination
     */
    function getSuiSwapData(bytes32 orderHash) 
        external 
        view 
        returns (SuiSwapData memory) 
    {
        return suiSwaps[orderHash];
    }

    /**
     * @notice Updates SUI escrow reference data
     * @dev Called by relayer when SUI escrow is created
     */
    function updateSuiEscrowData(
        bytes32 orderHash,
        uint64 suiEscrowObjectId,
        bytes32 suiTxHash
    ) external onlyOwner {
        if (!suiSwaps[orderHash].isActive) revert SwapNotFound();
        
        suiSwaps[orderHash].suiEscrowObjectId = suiEscrowObjectId;
        suiSwaps[orderHash].suiTxHash = suiTxHash;
    }

    /**
     * @notice Creates escrow with custom SUI-optimized timelocks
     */
    function _createSrcEscrowWithTimelocks(
        IBaseEscrow.Immutables memory immutables,
        SuiSwapTimelocks memory customTimelocks
    ) internal {
        // Pack custom timelocks into the standard Timelocks format
        Timelocks packedTimelocks = _packSuiTimelocks(customTimelocks);
        immutables.timelocks = packedTimelocks.setDeployedAt(block.timestamp);
        
        bytes32 salt = immutables.hashMem();
        address escrow = _deployEscrow(salt, msg.value, ESCROW_SRC_IMPLEMENTATION);
        
        // Validate sufficient funds were deposited
        if (escrow.balance < immutables.safetyDeposit || 
            IERC20(immutables.token.get()).balanceOf(escrow) < immutables.amount) {
            revert InsufficientEscrowBalance();
        }
    }

    /**
     * @notice Validates timelock configuration for cross-chain safety
     */
    function _validateSuiTimelocks(SuiSwapTimelocks memory timelocks) internal pure {
        // Ensure SUI withdrawal happens before ETH cancellation
        if (timelocks.suiWithdrawal >= timelocks.ethCancellation) {
            revert InvalidTimelock();
        }
        
        // Ensure ETH withdrawal happens before SUI cancellation  
        if (timelocks.ethWithdrawal >= timelocks.suiCancellation) {
            revert InvalidTimelock();
        }
        
        // Ensure proper progression of timelock stages
        if (timelocks.ethWithdrawal >= timelocks.ethPublicWithdrawal ||
            timelocks.ethPublicWithdrawal >= timelocks.ethCancellation ||
            timelocks.ethCancellation >= timelocks.ethPublicCancellation) {
            revert InvalidTimelock();
        }
        
        if (timelocks.suiWithdrawal >= timelocks.suiPublicWithdrawal ||
            timelocks.suiPublicWithdrawal >= timelocks.suiCancellation) {
            revert InvalidTimelock();
        }
    }

    /**
     * @notice Packs SUI-specific timelocks into standard format
     */
    function _packSuiTimelocks(SuiSwapTimelocks memory sui) 
        internal 
        pure 
        returns (Timelocks) 
    {
        // Pack the timelock values into a single uint256
        // This is a simplified version - actual implementation would use bit manipulation
        uint256 packed = 0;
        packed |= uint256(sui.ethWithdrawal);
        packed |= uint256(sui.ethPublicWithdrawal) << 32;
        packed |= uint256(sui.ethCancellation) << 64;
        packed |= uint256(sui.ethPublicCancellation) << 96;
        packed |= uint256(sui.suiWithdrawal) << 128;
        packed |= uint256(sui.suiPublicWithdrawal) << 160;
        packed |= uint256(sui.suiCancellation) << 192;
        
        return Timelocks.wrap(packed);
    }

    /**
     * @notice Emergency function to mark swap as inactive
     * @dev Only callable by owner in case of critical issues
     */
    function deactivateSwap(bytes32 orderHash) external onlyOwner {
        suiSwaps[orderHash].isActive = false;
    }

    /**
     * @notice Batch function for handling multiple cross-chain operations
     */
    function batchProcessSuiSwaps(
        bytes32[] calldata orderHashes,
        uint64[] calldata suiEscrowObjectIds,
        bytes32[] calldata suiTxHashes
    ) external onlyOwner {
        if (orderHashes.length != suiEscrowObjectIds.length || 
            orderHashes.length != suiTxHashes.length) {
            revert("Array length mismatch");
        }
        
        for (uint256 i = 0; i < orderHashes.length; i++) {
            if (suiSwaps[orderHashes[i]].isActive) {
                suiSwaps[orderHashes[i]].suiEscrowObjectId = suiEscrowObjectIds[i];
                suiSwaps[orderHashes[i]].suiTxHash = suiTxHashes[i];
            }
        }
    }
}