# USDP Liquidity Incentives

A comprehensive reference for the on-chain liquidity incentives system implemented in [USDPLiquidityIncentives.sol](USDPLiquidityIncentives.sol).

Contents
- [1) Overview and Purpose](#1-overview-and-purpose)
- [2) Architecture Summary](#2-architecture-summary)
- [3) Access Control / Roles & Permissions](#3-access-control--roles--permissions)
- [4) Public/External Interface Documentation](#4-publicexternal-interface-documentation)
- [5) Admin-Only Functions & Runbooks](#5-admin-only-functions--runbooks)
- [6) Reward Mechanics](#6-reward-mechanics)
- [7) User Flows](#7-user-flows)
- [8) Events and Errors](#8-events-and-errors)
- [9) Modifiers and Internal Guards](#9-modifiers-and-internal-guards)
- [10) Deployment and Initialization](#10-deployment-and-initialization)
- [11) Security Considerations](#11-security-considerations)
- [12) Upgradeability/Immutability](#12-upgradeabilityimmutability)
- [13) Gas and Performance Notes](#13-gas-and-performance-notes)
- [14) Integration Guide](#14-integration-guide)
- [15) Testing Checklist](#15-testing-checklist)

---

## 1) Overview and Purpose

The contract [contract USDPLiquidityIncentives](USDPLiquidityIncentives.sol:42) implements an LP staking and market-making incentives system for the USDP ecosystem. It enables:
- Liquidity providers to stake LP tokens into pools and earn rewards funded by a treasury under an emission schedule.
- Dynamic reward adjustments using pool allocation weights, a bootstrap multiplier, and a volume/stability multiplier.
- Market maker rebates and gas subsidies funded via a treasury.

Key features and constraints
- Staking and claiming gates can be toggled; emergency pause halts operations.
- Emissions follow a halving schedule and are capped by a total emissions limit.
- Rewards per user are multiplied by a time-lock “tier” multiplier at claim time (not at accrual time).
- Volume/stability and APY values are updatable by authorized addresses (off-chain fed).
- Owner, governance, authorized updaters, and emergency guardians have distinct permissions enforced by modifiers.

---

## 2) Architecture Summary

Core dependencies and contracts
- ERC20 interface: [import IERC20](USDPLiquidityIncentives.sol:4)
- Local interfaces:
  - [interface ITreasury](USDPLiquidityIncentives.sol:7): funding and stability operations.
  - [interface IGovernance](USDPLiquidityIncentives.sol:16): role queries and proposal execution (governance gate).
  - [interface IOracle](USDPLiquidityIncentives.sol:22): price/volume data (not directly consumed in reward math).
  - [interface ILPToken](USDPLiquidityIncentives.sol:29): LP token metadata and reserves.
- The contract interacts with:
  - Reward token (an ERC20) for user payouts.
  - LP tokens for staking/unstaking.
  - A Treasury for funding market maker rebates/subsidies and contract funding.

Storage layout highlights (selected)
- Pools array tracks per-pool state (LP token, DEX, alloc points, lastRewardTime, accRewardPerShare, totalStaked, baseAPY, volumeMultiplier, status flags).
- User positions are tracked per pool with amount, rewardDebt, tiers, locks, and accumulated pending.
- Global rewardConfig defines emissionRate, totalEmissions cap, emittedRewards tally, bootstrap end, halving interval, and a halving reference timestamp.
- Role gates use mappings: authorized updaters and emergency guardians. Governance is a single address. Owner/pendingOwner handles ownership transfer.
- Global switches: emergencyPaused, stakingEnabled, claimingEnabled. Anti-gaming minStakingInterval per user.

Units and constants
- Time in seconds. Rates use “per second” emission and basis points (1e4) multipliers. LP/reward tokens assumed 18 decimals.

---

## 3) Access Control / Roles & Permissions

Modifiers
- [modifier onlyOwner()](USDPLiquidityIncentives.sol:64): caller must equal stored owner address.
- [modifier onlyAuthorized()](USDPLiquidityIncentives.sol:270): caller is owner or in authorizedUpdaters.
- [modifier onlyEmergencyGuardian()](USDPLiquidityIncentives.sol:275): caller is owner or in emergencyGuardians.
- [modifier onlyGovernance()](USDPLiquidityIncentives.sol:280): caller must be exactly the governance address.
- [modifier whenNotPaused()](USDPLiquidityIncentives.sol:285): emergencyPaused must be false.
- [modifier validPool(uint256)](USDPLiquidityIncentives.sol:290): poolId must exist and the pool must be active.
- [modifier activeMarketMaker(address)](USDPLiquidityIncentives.sol:296): market maker must be active.

Role capabilities (non-exhaustive; see sections below for the linked functions)
- Owner: management functions including [function transferOwnership(address)](USDPLiquidityIncentives.sol:69), [function acceptOwnership()](USDPLiquidityIncentives.sol:74), [function emergencyUnpause()](USDPLiquidityIncentives.sol:965), [function emergencyWithdraw(address,uint256)](USDPLiquidityIncentives.sol:976), [function setAuthorizedUpdater(address,bool)](USDPLiquidityIncentives.sol:996), [function setEmergencyGuardian(address,bool)](USDPLiquidityIncentives.sol:1003), [function updateCoreContracts(address,address,address)](USDPLiquidityIncentives.sol:1011).
- Governance: emissions/weights/bootstrap control via [function updateEmissionRate(uint256,uint256)](USDPLiquidityIncentives.sol:904), [function updatePoolWeights(uint256[],uint256[])](USDPLiquidityIncentives.sol:919), [function endBootstrapPeriod()](USDPLiquidityIncentives.sol:938).
- Authorized updaters: pool adds/updates, market maker ops, data feeds, ops flags, funding via [function addPool(address,address,uint256,uint256)](USDPLiquidityIncentives.sol:349), [function updatePool(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:393), [function updateVolumeData(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:747), [function processMarketMakerRebate(address,uint256,uint256)](USDPLiquidityIncentives.sol:682), [function provideGasSubsidy(address,uint256)](USDPLiquidityIncentives.sol:717), [function setOperationsStatus(bool,bool)](USDPLiquidityIncentives.sol:984), [function setMinStakingInterval(uint256)](USDPLiquidityIncentives.sol:1023), [function fundFromTreasury(uint256)](USDPLiquidityIncentives.sol:1029).
- Emergency guardians: [function emergencyPause()](USDPLiquidityIncentives.sol:956).

Pause semantics
- Emergency pause disables staking and claiming via flags toggled in [function emergencyPause()](USDPLiquidityIncentives.sol:956) and re-enabled only by [function emergencyUnpause()](USDPLiquidityIncentives.sol:965).
- In addition, authorized may toggle staking/claiming independently via [function setOperationsStatus(bool,bool)](USDPLiquidityIncentives.sol:984).

---

## 4) Public/External Interface Documentation

Legend
- All function signature references below link to their declarations in [USDPLiquidityIncentives.sol](USDPLiquidityIncentives.sol).
- Units: seconds for time, basis points (BP = 1e4) for percentages, token amounts use token decimals (commonly 18 decimals).

Ownership
- [function transferOwnership(address)](USDPLiquidityIncentives.sol:69)
  - Purpose: Set a pending owner to later accept ownership.
  - Params: newOwner (address != 0).
  - State changes: sets pendingOwner.
  - Preconditions/reverts: onlyOwner; newOwner != 0.
  - Events: [event OwnershipTransferred(address,address)](USDPLiquidityIncentives.sol:249) is emitted by accept, not here.
- [function acceptOwnership()](USDPLiquidityIncentives.sol:74)
  - Purpose: Pending owner accepts and becomes owner.
  - State changes: owner updated, pendingOwner cleared.
  - Preconditions/reverts: msg.sender == pendingOwner.
  - Events: [event OwnershipTransferred(address,address)](USDPLiquidityIncentives.sol:249).

Constructor
- [constructor(address,address,address,address,address,uint256)](USDPLiquidityIncentives.sol:305)
  - Params: usdpToken, rewardToken, treasury, governance, oracle, startTime (must be in the future).
  - Effects: initializes core addresses, emission config defaults, grants deployer authorized updater and emergency guardian.
  - Preconditions/reverts: nonzero required addresses except oracle/governance may be zero; startTime > now.
  - Note: owner is not set in constructor; see Security Considerations.

Pool management
- [function addPool(address,address,uint256,uint256)](USDPLiquidityIncentives.sol:349)
  - Purpose: Add a new staking pool.
  - Params: lpToken, dex, allocPoint, baseAPY (BP, max 10000).
  - Preconditions: onlyAuthorized; lpToken/dex != 0; baseAPY ≤ MAX; LP must contain USDP; pool must not already exist.
  - State changes: pushes pool, updates totalAllocPoint, maps lpToken→poolId, marks DEX supported.
  - Events: [event PoolAdded(uint256,address,address,uint256)](USDPLiquidityIncentives.sol:228).
- [function updatePool(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:393)
  - Purpose: Update pool alloc points and base APY.
  - Params: poolId, allocPoint, baseAPY (BP, ≤ MAX).
  - Preconditions: validPool; onlyAuthorized.
  - State changes: calls internal _updatePool; adjusts totalAllocPoint; writes pool.allocPoint/baseAPY.
  - Events: [event PoolUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:229).
- [function calculatePoolReward(uint256,uint256)](USDPLiquidityIncentives.sol:438) view
  - Purpose: Compute pool reward for a time period.
  - Params: poolId, timeElapsed (sec).
  - Returns: reward amount.
  - Notes: multiplies base emission by pool share and volume multiplier; applies bootstrap multiplier; caps by totalEmissions.
- [function getCurrentEmissionRate()](USDPLiquidityIncentives.sol:466) view
  - Purpose: Current emission rate after applying halving schedule.
  - Returns: emission rate per second.

Staking
- [function stakeLPTokens(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:485)
  - Purpose: Stake LP into a pool with optional lock tier (1/2/3).
  - Params: poolId, amount (must be ≥ MIN stake), lockDuration (0 no lock; 1,2,3 for tiers).
  - Preconditions/reverts: validPool; whenNotPaused; nonReentrant; stakingEnabled; amount ≥ min; lockDuration ≤ 3; per-user min staking interval.
  - State changes: settles pending to user.pendingRewards, transfers LP in, updates balances, sets tier and lock end time, updates rewardDebt, stats.
  - Events: [event Staked(address,uint256,uint256,uint256)](USDPLiquidityIncentives.sol:230).
- [function unstakeLPTokens(uint256,uint256)](USDPLiquidityIncentives.sol:540)
  - Purpose: Unstake LP from a pool.
  - Params: poolId, amount (≤ staked).
  - Preconditions/reverts: validPool; whenNotPaused; nonReentrant; user amount ≥ amount; now ≥ lockEndTime.
  - State changes: settles pending to pendingRewards, reduces amount, updates rewardDebt and pool stats, transfers LP out.
  - Events: [event Unstaked(address,uint256,uint256)](USDPLiquidityIncentives.sol:231).
- [function claimRewards(uint256)](USDPLiquidityIncentives.sol:574)
  - Purpose: Claim accumulated rewards from a pool.
  - Params: poolId.
  - Preconditions/reverts: validPool; whenNotPaused; nonReentrant; claimingEnabled; totalRewards > 0.
  - State changes: applies tier multiplier at claim time; zeros pendingRewards; updates rewardDebt, lastClaimTime, totalEarned, global distributed; transfers reward tokens.
  - Events: [event RewardsClaimed(address,uint256,uint256)](USDPLiquidityIncentives.sol:232).
- [function compoundRewards(uint256)](USDPLiquidityIncentives.sol:608)
  - Purpose: Non-implemented; always reverts.
  - Reverts: "NOT_IMPLEMENTED".

Market makers
- [function addMarketMaker(address,uint256,uint256,uint256)](USDPLiquidityIncentives.sol:633)
  - Purpose: Register an active market maker with targets and rebate rate (BP).
  - Preconditions/reverts: onlyAuthorized; nonzero address; rebateRate ≤ BASIS_POINTS; not already active.
  - Events: [event MarketMakerAdded(address,uint256,uint256)](USDPLiquidityIncentives.sol:235).
- [function removeMarketMaker(address)](USDPLiquidityIncentives.sol:661)
  - Purpose: Deactivate a market maker and remove from list.
  - Preconditions/reverts: onlyAuthorized; must be active.
  - Complexity: linear scan over marketMakerList to remove.
  - Events: [event MarketMakerRemoved(address)](USDPLiquidityIncentives.sol:236).
- [function processMarketMakerRebate(address,uint256,uint256)](USDPLiquidityIncentives.sol:682)
  - Purpose: Pay fee rebate based on volume/fees, funded by treasury.
  - Preconditions/reverts: onlyAuthorized; activeMarketMaker; treasury.deployStabilityFunds must succeed (reverts "TREASURY_REBATE_FAILED" on failure).
  - State: updates maker totals, daily volume, last activity; attempts treasury transfer; emits event.
  - Events: [event RebatePaid(address,uint256,uint256)](USDPLiquidityIncentives.sol:237).
- [function provideGasSubsidy(address,uint256)](USDPLiquidityIncentives.sol:717)
  - Purpose: Provide gas subsidy to a market maker (simplified conversion).
  - Preconditions/reverts: onlyAuthorized; activeMarketMaker; treasury transfer must succeed (reverts "TREASURY_SUBSIDY_FAILED" on failure).
  - State: updates accrued subsidy; attempts treasury transfer; emits event.
  - Events: [event GasSubsidyPaid(address,uint256)](USDPLiquidityIncentives.sol:238).

Volume and price data
- [function updateVolumeData(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:747)
  - Purpose: Feed 24h volume and a price stability score; recompute pool multiplier and dynamic APY.
  - Params: poolId, dailyVolume, priceStability (0–10000).
  - Preconditions/reverts: validPool; onlyAuthorized.
  - State changes: records the metrics; sets pool.volumeMultiplier; sets pool.baseAPY to dynamic value.
  - Events: [event VolumeUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:240), [event APYUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:241).

View functions
- [function pendingRewards(uint256,address)](USDPLiquidityIncentives.sol:835) view
  - Purpose: Calculate a user’s current claimable (includes tier multiplier).
  - Returns: pending reward amount.
- [function getPoolInfo(uint256)](USDPLiquidityIncentives.sol:859) view
- [function getUserInfo(uint256,address)](USDPLiquidityIncentives.sol:868) view
- [function getMarketMakerInfo(address)](USDPLiquidityIncentives.sol:875) view
- [function getRewardConfig()](USDPLiquidityIncentives.sol:881) view
- [function poolLength()](USDPLiquidityIncentives.sol:887) view
- [function getAllMarketMakers()](USDPLiquidityIncentives.sol:893) view

Governance
- [function updateEmissionRate(uint256,uint256)](USDPLiquidityIncentives.sol:904)
  - Purpose: Set emission rate per second and total emissions cap.
  - Preconditions/reverts: onlyGovernance; newTotalEmissions ≥ emittedRewards.
  - Events: [event EmissionRateUpdated(uint256,uint256)](USDPLiquidityIncentives.sol:242).
- [function updatePoolWeights(uint256[],uint256[])](USDPLiquidityIncentives.sol:919)
  - Purpose: Batch update pool allocation points.
  - Preconditions/reverts: onlyGovernance; array length equality; each poolId must exist.
  - State changes: calls _updatePool per ID; rewrites totalAllocPoint, pool.allocPoint; emits [event PoolUpdated](USDPLiquidityIncentives.sol:229) for each.
- [function endBootstrapPeriod()](USDPLiquidityIncentives.sol:938)
  - Purpose: End bootstrap early for all pools.
  - Preconditions/reverts: onlyGovernance; must be before current bootstrapEnd.
  - Effects: sets rewardConfig.bootstrapEnd=now; sets all pools isBootstrap=false.
  - Events: [event BootstrapPeriodEnded(uint256)](USDPLiquidityIncentives.sol:243).

Emergency
- [function emergencyPause()](USDPLiquidityIncentives.sol:956)
  - Purpose: Immediately pause operations and disable staking/claiming.
  - Preconditions: onlyEmergencyGuardian.
  - Events: [event EmergencyPaused(uint256)](USDPLiquidityIncentives.sol:245).
- [function emergencyUnpause()](USDPLiquidityIncentives.sol:965)
  - Purpose: Resume operations and re-enable staking/claiming.
  - Preconditions: onlyOwner.
  - Events: [event EmergencyUnpaused(uint256)](USDPLiquidityIncentives.sol:246).
- [function emergencyWithdraw(address,uint256)](USDPLiquidityIncentives.sol:976)
  - Purpose: Owner withdraws arbitrary ERC20 from the contract.
  - Preconditions: onlyOwner.
  - Events: [event RewardTokensRecovered(address,uint256)](USDPLiquidityIncentives.sol:248).
- [function setOperationsStatus(bool,bool)](USDPLiquidityIncentives.sol:984)
  - Purpose: Toggle stakingEnabled and claimingEnabled.
  - Preconditions: onlyAuthorized.

Admin
- [function setAuthorizedUpdater(address,bool)](USDPLiquidityIncentives.sol:996)
- [function setEmergencyGuardian(address,bool)](USDPLiquidityIncentives.sol:1003)
- [function updateCoreContracts(address,address,address)](USDPLiquidityIncentives.sol:1011)
  - Purpose: Update treasury, governance, and oracle addresses (0 keeps existing).
  - Preconditions: onlyOwner.
- [function setMinStakingInterval(uint256)](USDPLiquidityIncentives.sol:1023)
  - Purpose: Set per-user minimum interval between stakes (seconds).
  - Preconditions: onlyAuthorized.
- [function fundFromTreasury(uint256)](USDPLiquidityIncentives.sol:1029)
  - Purpose: Pull reward tokens from treasury into this contract.
  - Preconditions: onlyAuthorized.
  - Events: [event TreasuryFundingReceived(uint256)](USDPLiquidityIncentives.sol:247).

Example calls (user-facing)
- Solidity (stake/unstake/claim)
  ```
  // Assume IERC20 lp = IERC20(lpToken);
  // Approve first
  lp.approve(address(usdpl), amount);

  // Stake with 4-week lock tier (2)
  usdpl.stakeLPTokens(poolId, amount, 2);

  // Claim rewards
  usdpl.claimRewards(poolId);

  // Unstake after lock end
  usdpl.unstakeLPTokens(poolId, amount);
  ```
- ethers.js (stake/unstake/claim)
  ```
  const usdpl = new ethers.Contract(usdplAddress, abi, signer);
  const lp = new ethers.Contract(lpAddress, erc20Abi, signer);

  await lp.approve(usdplAddress, amount);
  await usdpl.stakeLPTokens(poolId, amount, 2);

  const pending = await usdpl.pendingRewards(poolId, await signer.getAddress());
  if (pending.gt(0)) {
    await usdpl.claimRewards(poolId);
  }

  await usdpl.unstakeLPTokens(poolId, amount);
  ```

---

## 5) Admin-Only Functions & Runbooks

Common operations
- Add a pool:
  1) Verify LP contains USDP; decide allocPoint and initial baseAPY target.
  2) Call [function addPool(address,address,uint256,uint256)](USDPLiquidityIncentives.sol:349) (onlyAuthorized).
  3) Optionally fund rewards via [function fundFromTreasury(uint256)](USDPLiquidityIncentives.sol:1029).
- Adjust a pool:
  - Call [function updatePool(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:393) to change allocPoint/baseAPY.
- Adjust global emissions (governance):
  - Call [function updateEmissionRate(uint256,uint256)](USDPLiquidityIncentives.sol:904) with new rate and total cap.
- Update pool weights in batch (governance):
  - Call [function updatePoolWeights(uint256[],uint256[])](USDPLiquidityIncentives.sol:919).
- Update volume & stability (oracle feed via authorized updater):
  - Call [function updateVolumeData(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:747).
- Pause/unpause:
  - [function emergencyPause()](USDPLiquidityIncentives.sol:956) (guardian).
  - [function emergencyUnpause()](USDPLiquidityIncentives.sol:965) (owner).
  - Fine-grained gates: [function setOperationsStatus(bool,bool)](USDPLiquidityIncentives.sol:984) (authorized).

Guardrails and constraints
- Max APY enforcement on pool config; arrays length checks; pool existence checks.
- Treasury funding calls use try/catch and revert with explicit strings on failure.
- Note: Only owner can unpause after an emergency pause.

---

## 6) Reward Mechanics

Accrual at pool level
- Internal updater distributes a time-proportional reward to each pool:  
  reward = getCurrentEmissionRate() × timeElapsed × (pool.allocPoint / totalAllocPoint)
- Adjustments:
  - If pool is in bootstrap and before bootstrapEnd: multiply by a bootstrap multiplier.
  - Then multiply by pool.volumeMultiplier (basis points).
  - Cap so emittedRewards + reward ≤ totalEmissions.
- Accumulator:
  - accRewardPerShare increases by reward × 1e12 / pool.totalStaked.

User-level pending and claim
- Pending calculation:
  - pending = (user.amount × accRewardPerShare / 1e12) − user.rewardDebt
  - totalRewards = user.pendingRewards + pending
  - claimable = totalRewards × tierMultiplier (BP) / 10000
- On claim:
  - pendingRewards set to 0; rewardDebt updated; totalEarned and lastClaimTime updated; reward tokens transferred.
- Important: emittedRewards is incremented by pool-level reward prior to tier application. The additional tier multiplier applied at claim time is not reflected in emittedRewards. Treasury funding must therefore cover tier-amplified payouts.

Halving and bootstrap
- Halving: [function getCurrentEmissionRate()](USDPLiquidityIncentives.sol:466) halves emissionRate once per full halvingInterval elapsed since lastHalving reference; the lastHalving value is not advanced after computation.
- Bootstrap: pool.isBootstrap and current time < bootstrapEnd trigger a further multiplier in pool reward.

Edge cases
- If pool.totalStaked == 0 at update time: lastRewardTime advances but no rewards accrue.
- baseAPY shown on pools is adjusted by updateVolumeData/dynamic APY logic but is not used in calculatePoolReward; it is present for signaling/display and may differ from emission-driven actual yields.
- If the contract’s rewardToken balance is insufficient at claim time, the transfer reverts; ensure funding via [function fundFromTreasury(uint256)](USDPLiquidityIncentives.sol:1029).

Precision and units
- Basis points for multipliers and APY-like parameters.
- Emissions are “per second”.
- Per-share accumulator uses 1e12 scaling.

---

## 7) User Flows

Provide liquidity (stake)
- Approve LP token for the contract.
- Call [function stakeLPTokens(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:485) with chosen lock tier (0/1/2/3).
- Constraints: staking must be enabled; respect minStakingInterval; amount ≥ minimum.

Claim rewards
- Read [function pendingRewards(uint256,address)](USDPLiquidityIncentives.sol:835).
- Call [function claimRewards(uint256)](USDPLiquidityIncentives.sol:574) if > 0 and claiming is enabled.

Unstake (withdraw)
- Ensure lockEndTime has passed if a lock was chosen.
- Call [function unstakeLPTokens(uint256,uint256)](USDPLiquidityIncentives.sol:540).

Common errors (string reverts)
- INVALID_LP_TOKEN / INVALID_DEX / APY_TOO_HIGH / POOL_EXISTS: misconfiguration when adding pools.
- LP_TOKEN_MUST_CONTAIN_USDP: pool addition constraint.
- STAKING_DISABLED / CLAIMING_DISABLED: ops flags disabled.
- INSUFFICIENT_AMOUNT: below minimum stake.
- INVALID_LOCK_DURATION / STAKING_TOO_FREQUENT: lock tier invalid or rate-limited.
- INSUFFICIENT_STAKED / STILL_LOCKED: cannot unstake.
- NO_REWARDS: nothing to claim.
- EMERGENCY_PAUSED: blocked by global pause.
- TREASURY_REBATE_FAILED / TREASURY_SUBSIDY_FAILED: treasury call failure.

Note: Custom error types are declared but not used by the current implementation; see Errors.

---

## 8) Events and Errors

Events
- [event PoolAdded(uint256,address,address,uint256)](USDPLiquidityIncentives.sol:228) — when a new pool is added.
- [event PoolUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:229) — when pool alloc/baseAPY changes.
- [event Staked(address,uint256,uint256,uint256)](USDPLiquidityIncentives.sol:230) — on user stake (amount, lock).
- [event Unstaked(address,uint256,uint256)](USDPLiquidityIncentives.sol:231) — on user unstake.
- [event RewardsClaimed(address,uint256,uint256)](USDPLiquidityIncentives.sol:232) — on reward claim.
- [event CompoundStaking(address,uint256,uint256)](USDPLiquidityIncentives.sol:233) — unused in current logic; emitted nowhere.
- [event MarketMakerAdded(address,uint256,uint256)](USDPLiquidityIncentives.sol:235) — on MM added.
- [event MarketMakerRemoved(address)](USDPLiquidityIncentives.sol:236) — on MM removed/deactivated.
- [event RebatePaid(address,uint256,uint256)](USDPLiquidityIncentives.sol:237) — on rebate payout and volume record.
- [event GasSubsidyPaid(address,uint256)](USDPLiquidityIncentives.sol:238) — on gas subsidy payout.
- [event VolumeUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:240) — when pool volume/stability updated.
- [event APYUpdated(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:241) — when dynamic APY recalculated.
- [event EmissionRateUpdated(uint256,uint256)](USDPLiquidityIncentives.sol:242) — when emission rate/cap updated.
- [event BootstrapPeriodEnded(uint256)](USDPLiquidityIncentives.sol:243) — bootstrap ended.
- [event EmergencyPaused(uint256)](USDPLiquidityIncentives.sol:245), [event EmergencyUnpaused(uint256)](USDPLiquidityIncentives.sol:246) — pause status changes.
- [event TreasuryFundingReceived(uint256)](USDPLiquidityIncentives.sol:247) — after treasury funds contract.
- [event RewardTokensRecovered(address,uint256)](USDPLiquidityIncentives.sol:248) — owner recovers tokens.
- [event OwnershipTransferred(address,address)](USDPLiquidityIncentives.sol:249) — owner change (via accept).

Custom errors (declared; not used by current code)
- [error InvalidPool()](USDPLiquidityIncentives.sol:255)
- [error InsufficientStake()](USDPLiquidityIncentives.sol:256)
- [error StillLocked()](USDPLiquidityIncentives.sol:257)
- [error EmergencyPausedError()](USDPLiquidityIncentives.sol:258)
- [error UnauthorizedAccess()](USDPLiquidityIncentives.sol:259)
- [error InvalidParameters()](USDPLiquidityIncentives.sol:260)
- [error InsufficientRewards()](USDPLiquidityIncentives.sol:261)
- [error MarketMakerNotActive()](USDPLiquidityIncentives.sol:262)
- [error StakingTooFrequent()](USDPLiquidityIncentives.sol:263)
- [error InvalidLockDuration()](USDPLiquidityIncentives.sol:264)

---

## 9) Modifiers and Internal Guards

- [modifier nonReentrant()](USDPLiquidityIncentives.sol:50) — simple status-flag guard on external entrypoints.
- [modifier onlyOwner()](USDPLiquidityIncentives.sol:64) — restricts to owner.
- [modifier onlyAuthorized()](USDPLiquidityIncentives.sol:270) — owner or authorizedUpdater.
- [modifier onlyEmergencyGuardian()](USDPLiquidityIncentives.sol:275) — owner or guardian.
- [modifier onlyGovernance()](USDPLiquidityIncentives.sol:280) — governance address only.
- [modifier whenNotPaused()](USDPLiquidityIncentives.sol:285) — blocks while emergencyPaused.
- [modifier validPool(uint256)](USDPLiquidityIncentives.sol:290) — pool exists and is active.
- [modifier activeMarketMaker(address)](USDPLiquidityIncentives.sol:296) — market maker is active.

---

## 10) Deployment and Initialization

Constructor
- [constructor(address,address,address,address,address,uint256)](USDPLiquidityIncentives.sol:305)
  - usdpToken, rewardToken, treasury, governance, oracle, startTime.
  - startTime must be strictly in the future (now < startTime).
  - Initial reward configuration:
    - emissionRate = 1e18 tokens/sec
    - totalEmissions = 1,000,000e18
    - emittedRewards = 0
    - bootstrapEnd = startTime + 90 days
    - halvingInterval = 180 days
    - lastHalving = startTime
  - Deployer is added as authorized updater and emergency guardian.

Post-deploy setup (recommended)
- Fund the contract with reward tokens (from treasury) via [function fundFromTreasury(uint256)](USDPLiquidityIncentives.sol:1029).
- Add initial pools via [function addPool(address,address,uint256,uint256)](USDPLiquidityIncentives.sol:349).
- Optionally, set pool weights via [function updatePoolWeights(uint256[],uint256[])](USDPLiquidityIncentives.sol:919).
- Feed initial volume/stability via [function updateVolumeData(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:747).
- Critical note: The contract does not set owner in the constructor. Without an owner, onlyOwner functions (e.g., unpausing) are unusable. Ensure governance/authorized flows suffice operationally, or update the deployment process/codebase accordingly in future versions.

Network assumptions
- Time-based logic uses block.timestamp (seconds). No chain-specific dependencies.

---

## 11) Security Considerations

- Reentrancy: [modifier nonReentrant()](USDPLiquidityIncentives.sol:50) protects staking/claiming paths. Market maker funding functions are not non-reentrant but call an external treasury using try/catch before emitting events and after internal state updates; authorized-only limits exposure but treasury trust is assumed.
- Access control hygiene: Maintain tight control over authorized updaters and emergency guardians. Governance should be a secure contract/address.
- Balance/allowance checks: Reward payouts use a safe low-level transfer wrapper; insufficient balance will revert. Ensure treasury funding keeps contract solvent relative to tier-multiplied claims.
- Arithmetic: Solidity 0.8+ checked arithmetic; per-share uses 1e12 scaling.
- Timestamp reliance: Halving and locks use block timestamps; miners can skew by seconds, but economic impact is limited.
- Emissions vs payout: Tier multiplier is applied at claim time but not counted in emittedRewards, which can cause treasury shortfalls if not funded accordingly.
- Pause behavior: Emergency pause disables staking and claiming; users cannot withdraw while paused (no emergency user-withdraw function).

---

## 12) Upgradeability/Immutability

- The contract is not declared upgradeable and does not include proxy patterns. It is a standard deployed contract.
- Some core dependencies are updatable by the owner via [function updateCoreContracts(address,address,address)](USDPLiquidityIncentives.sol:1011) (treasury, governance, oracle).
- usdpToken and rewardToken are immutable after construction.

---

## 13) Gas and Performance Notes

- Loops:
  - Removing a market maker scans marketMakerList linearly; gas grows with number of market makers.
  - Ending bootstrap loops over all pools.
  - Batch pool weight updates loop over provided arrays.
- Accrual updates amortize via on-demand _updatePool calls.
- Users can minimize gas by:
  - Aggregating stakes rather than frequent small stakes (respects minStakingInterval).
  - Claiming when meaningful to avoid small transfers.
  - Avoiding staking shortly before a lock-expiry unless needed.

---

## 14) Integration Guide

Detecting claimable rewards
- Read [function pendingRewards(uint256,address)](USDPLiquidityIncentives.sol:835).
- If > 0, call [function claimRewards(uint256)](USDPLiquidityIncentives.sol:574).

Idempotency and retries
- Staking/unstaking/claiming are not idempotent but safe to retry if the previous tx reverted; re-reads will reflect updated rewardDebt and balances.

Sequence for staking
- Approve LP token to contract.
- Call [function stakeLPTokens(uint256,uint256,uint256)](USDPLiquidityIncentives.sol:485).
- Track emitted [event Staked(address,uint256,uint256,uint256)](USDPLiquidityIncentives.sol:230) to confirm.

Sequence for claiming
- Optionally read [function pendingRewards(uint256,address)](USDPLiquidityIncentives.sol:835).
- Call [function claimRewards(uint256)](USDPLiquidityIncentives.sol:574).
- Track [event RewardsClaimed(address,uint256,uint256)](USDPLiquidityIncentives.sol:232).

Script/dApp integration notes
- Always check stakingEnabled/claimingEnabled via view of public flags if surfaced, or infer via revert reasons.
- After governance/authorized changes (emissions, pool weights, volume multipliers), UI should refresh projected APY and claimable views.
- Funding: robust systems should monitor contract rewardToken balance and emittedRewards vs totalEmissions.

ABI
- The ABI can be generated directly from [USDPLiquidityIncentives.sol](USDPLiquidityIncentives.sol). Ensure your toolchain includes the events and view methods documented above.

---

## 15) Testing Checklist

- Constructor and initialization:
  - Reverts on invalid inputs; startTime in future; initial rewardConfig as expected.
- Ownership and roles:
  - Only designated roles can call protected functions; inability to call onlyOwner flows unless owner is set.
- Pool lifecycle:
  - Add pools (reject duplicates or invalid LP); update pools; validPool modifier gating.
- Staking:
  - Stake with/without lock; minStakingInterval enforced; pending accumulation on restake; correct rewardDebt.
- Unstaking:
  - Cannot unstake before lockEndTime; transfers correct LP amount back; updates totals.
- Rewards:
  - Accrual over time; pendingRewards matches claim; claim applies tier multiplier; emitted events and state updates correct.
  - Cap against totalEmissions respected at pool level; test treasury funding sufficiency for tier-amplified claims.
- Emissions logic:
  - Halving schedule effect on rate; bootstrap multiplier application windows; volume multiplier and APY updates.
- Market maker:
  - Add/remove; rebate/subsidy flows; daily volume tracking; error handling on treasury failures.
- Pause and ops flags:
  - emergencyPause blocks staking/claiming; emergencyUnpause restores; setOperationsStatus toggles as expected.
- Admin updates:
  - updateCoreContracts address updates; setAuthorizedUpdater / setEmergencyGuardian; setMinStakingInterval.
