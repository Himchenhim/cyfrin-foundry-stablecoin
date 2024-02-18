1. Anchored or Pegged (Relative stability) -> $1.00
   1. Chainlink Price feed.
   2. Set a function to exchange ETH & BTC -> $$$
2. Stability Mechanism (Minting): Algorithmic (Decentralized)
   1. People can only menth the stablecoin with enough collateral (coded) 
3. Collatrela: Exogenous (Crypto)
   1. wETH (wrapped --> ERC20)
   2. wBTC (wrapped --> ERC20)g

Main function: "liquidate":
   example: $75 in ETH as collateral -- AND -- $50 in DSC 
            -> undercollateralized
            liquidator MUST pay (maximum) $50 in $DSC for liquidation $50 in $DSC of userToLiquidate
            -> 
            liquidator PAYS in $DSC from HIS LOAN (he DOES need to convert his collateral into DSC)
            ->
            liquidator gets $50 + $5 from "userToLiquidate" account on HIS OWN account of collaterals.
            OTHER $20 dollars STAY(!!!) on the  "userToLiquidate" account


1. What are our invariant/properties?
   1. ratio between collateral / loan. We always must have 200% amount of value in $ of collateral for our loan, which we perceive as our 100% amount. -> write fuzz test for it


1. Proper Oracle Use