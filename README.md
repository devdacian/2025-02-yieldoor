# Yieldoor contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the **Issues** page in your private contest repo (label issues as **Medium** or **High**)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Sonic, Base, Optimism, Arbitrum
___

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of [weird tokens](https://github.com/d-xo/weird-erc20) you want to integrate?
Protocol will work only with standard ERC20 tokens.

Note: 


# Audit scope

[yieldoor @ 2313f38e300f8b84929122aca647e727f0a4ddee](https://github.com/spacegliderrrr/yieldoor/tree/2313f38e300f8b84929122aca647e727f0a4ddee)
- [yieldoor/src/LendingPool.sol](yieldoor/src/LendingPool.sol)
- [yieldoor/src/Leverager.sol](yieldoor/src/Leverager.sol)
- [yieldoor/src/Strategy.sol](yieldoor/src/Strategy.sol)
- [yieldoor/src/Vault.sol](yieldoor/src/Vault.sol)
- [yieldoor/src/libraries/InterestRateUtils.sol](yieldoor/src/libraries/InterestRateUtils.sol)
- [yieldoor/src/libraries/ReserveLogic.sol](yieldoor/src/libraries/ReserveLogic.sol)
- [yieldoor/src/types/DataTypes.sol](yieldoor/src/types/DataTypes.sol)
- [yieldoor/src/yToken.sol](yieldoor/src/yToken.sol)


