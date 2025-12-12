# KipuBankV3

KipuBankV3 is basically an improved version of the previous KipuBank idea.  
This time I wanted the contract to behave more like something you’d actually see in a DeFi project, so everything inside the bank is handled in **USDC**, even if the user deposits other tokens.

To make that possible, the contract uses the **Universal Router (Uniswap v4)** to swap any ERC-20 token into USDC before updating the balance.  
This version was made to run on the Sepolia testnet and already comes with the Sepolia addresses for USDC, Permit2 and the router.

---

## Overview

The main idea is:

- The bank only stores USDC internally.
- Users can deposit:
  - USDC directly  
  - or **any ERC-20 token** that has trading support through Uniswap v4.
- If the token isn’t USDC:
  1. The contract receives it  
  2. Swaps it to USDC using the router  
  3. Credits the final USDC amount to the user's balance

There’s also a **bank cap**, which is just a limit on how much USDC the bank is allowed to hold.  
If a deposit or swap result would go beyond the cap, the transaction fails.

Some things from the previous version were kept, like the owner permissions and the optional Chainlink price feeds.

---

## Main Components

### File: `src/KipuBankV3.sol`

Here are the most important things inside the contract:

### **State Variables**
- USDC token reference  
- Universal Router reference  
- Permit2 reference  
- `bankCap` – the max USDC allowed  
- `totalUSDC` – how much the bank currently holds  
- `balances` – user balances (all in USDC)  
- `priceFeeds` – optional Chainlink feeds (kept from V2)  

### **Core Features**
- Everything is tracked in **USDC**
- The cap (`bankCap`) is checked on every deposit
- Owner functions:
  - change the cap  
  - change the owner  
  - set price feeds  
- Deposit/withdraw:
  - `depositUSDC`  
  - `withdrawUSDC`  

### **What’s New in V3**
- Support for depositing any ERC-20 token  
- Automatic swap to USDC using the Universal Router  
- Uses the types required by the assignment:
  - `Currency`
  - `PoolKey`
  - `Commands`
  - `Actions`
- New functions:
  - `depositArbitraryToken(...)`  
  - `_swapExactInputSingle(...)` (internal helper for the swap)  

The helper function builds the data needed to perform a single-pool exact-input swap and then calls `universalRouter.execute(...)`.

---

## Why It's Designed Like This

### **1. Using only USDC internally**
This makes everything easier:
- only one token to track  
- simpler math  
- enforcing the cap is straightforward  
- and it kinda matches how some real apps use USDC as the main currency  

### **2. Bank Cap**
The contract checks:

```solidity
require(totalUSDC + amountUSDC <= bankCap, "bank cap exceeded");
