const { ethers } = require("ethers");
const {
    buildOrder,
    signOrder,
    getLimitOrderV4Domain,
} = require("@1inch/limit-order-protocol-utils");
const crypto = require("crypto");

// --- CONFIG (Add these to your script) ---
const LOP_CONTRACT_ADDRESS = "0x..."; // From Step 1
const WETH_ADDRESS = "0x..."; // WETH address on your testnet
const MAKER_ASSET_ON_SUI = "0x...::coin::COIN"; // Placeholder for the asset on Sui

// --- Provider & Wallet ---
const provider = new ethers.JsonRpcProvider("http://127.0.0.1:8545");
const makerWallet = new ethers.Wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", provider);

async function createAndSignOrder() {
    console.log("📝 Creating and signing a limit order...");

    const chainId = (await provider.getNetwork()).chainId;
    const domain = getLimitOrderV4Domain(chainId, LOP_CONTRACT_ADDRESS);

    // 1. Generate the secret and hashlock for the HTLC
    const secret = crypto.randomBytes(32);
    const hashlock = crypto.createHash("sha256").update(secret).digest();

    // 2. Build the order structure
    // This is a simplified cross-chain order. The maker asset is on the EVM chain.
    // The taker asset is represented by an off-chain identifier.
    const order = buildOrder(
        {
            maker: makerWallet.address,
            makerAsset: WETH_ADDRESS,
            takerAsset: MAKER_ASSET_ON_SUI, // Off-chain identifier
            makingAmount: ethers.utils.parseEther("0.1").toString(),
            takingAmount: "1500000000000", // 1500 SUI (with 9 decimals)
        },
        {
            // The hashlock is included in the extension data
            extension: {
                hashlock: "0x" + hashlock.toString("hex"),
            },
        }
    );

    // 3. Sign the EIP-712 typed data
    const signature = await signOrder(domain, order, makerWallet);

    console.log("✅ Order created and signed successfully!");
    return { order, signature, secret };
}

// You will call this function in your main execution flow.