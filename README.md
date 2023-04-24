# Lending

Solidity contracts used in [Pawnfi](https://www.pawnfi.com/) lending.

## Overview

The Lending contract facilitates the support of collateralized borrowing and lending using both NFTs and ERC20 tokens. While forked from Compound (https://github.com/compound-finance/compound-protocol), this smart contract has been optimized for efficiency and NFT integration.

## Audits

- PeckShield ( - ) : [report](./audits/audits.pdf) (Also available in Chinese in the same folder)

## Contracts

### Installation

- To run lending, pull the repository from GitHub and install its dependencies. You will need [npm](https://docs.npmjs.com/cli/install) installed.

```bash
git clone https://github.com/PawnFi/Lending.git
cd Lending
npm install 
```
- Create an enviroment file named `.env` and fill the next enviroment variables

```
# Import private key
PRIVATEKEY= your private key 

# Add Infura provider keys
MAINNET_NETWORK=https://mainnet.infura.io/v3/YOUR_API_KEY
GOERLI_NETWORK=https://goerli.infura.io/v3/YOUR_API_KEY

```

### Compile

```
npx hardhat compile
```



### Local deployment

In order to deploy this code to a local testnet, you should install the npm package `@pawnfi/lending` and import the Comptroller bytecode located at `@pawnfi/lending/artifacts/contracts/Comptroller.sol/Comptroller.json`.
For example:

```typescript
import {
  abi as COMPTROLLER_ABI,
  bytecode as COMPTROLLER_BYTECODE,
} from '@pawnfi/lending/artifacts/contracts/Comptroller.sol/Comptroller.json'

// deploy the bytecode
```

This will ensure that you are testing against the same bytecode that is deployed to
mainnet and public testnets, and all Pawnfi code will correctly interoperate with
your local deployment.

### Using solidity interfaces

The Pawnfi lending interfaces are available for import into solidity smart contracts
via the npm artifact `@pawnfi/lending`, e.g.:

```solidity
import '@pawnfi/lending/contracts/CTokenInterfaces.sol';

contract MyContract {
  CErc20Interface cErc20;

  function doSomethingWithCErc20() {
    // cErc20.mint(...);
  }
}

```

## Discussion

For any concerns with the protocol, open an issue or visit us on [Discord](https://discord.com/invite/pawnfi) to discuss.

For security concerns, please email [dev@pawnfi.com](mailto:dev@pawnfi.com).

_© Copyright 2023, Pawnfi Ltd._

