# IMD PUMP (IMDPUMP)

A custom token launch on Ethereum (chain id 1), paired with IMD, built with Foundry.

| Item | Value |
| --- | --- |
| Token name | IMD PUMP |
| Token symbol | IMDPUMP |
| Decimals | 18 |
| Total supply | 1,000,000,000 IMDPUMP (`1000000000000000000000000000` minor units), minted once to the deployer |
| Transfer taxes | None. The token is a plain ERC-20 by the requester's choice. |
| Pair currency | IMD, `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` (18 decimals) |
| Fee and payout recipient | `0x83027AD9d0D5374335086c539dADD1db983441B0` |

## Contracts

### `IMDPumpToken` (`src/IMDPumpToken.sol`)

The token. Its constructor takes no arguments and mints the whole supply to `msg.sender`, which at
launch is the IMD factory. There is no owner, no minter, no pause, no blacklist and no `burnFrom`.
Holders may `burn` their own tokens, which reduces `totalSupply`. Nothing can ever increase the
supply. The contract rejects ETH.

### `IMDPumpRevenueSplitter` (`src/IMDPumpRevenueSplitter.sol`)

The application contract that implements the requester's "aggressive but sustainable" allocation of
eligible net platform revenue. Revenue is delivered in IMD; the contract splits it as follows.

| Bucket | Launch share | Where it goes |
| --- | --- | --- |
| IMD ecosystem treasury | 25% | `recipients.treasury` |
| Development and operations | 20% | `recipients.operations` |
| IMD NFT worker rewards | 20% | `recipients.nftWorkers` |
| IMD buyback and burn | 20% | `burnSink` (held as `pendingBurn` until set) |
| Developer IMD rewards | 15% | `recipients.developer` |

For every 100 IMD of eligible net revenue: 20 are burned, 15 go to the developer, 65 support the
treasury, operations and NFT workers. `imdDirectedBps()` reports the combined burn plus developer
share, 3,500 basis points (35%) at launch. All four paid-out recipients start as the requester's
payout address above; the owner can re-point each one.

Flow:

1. The operator sends IMD to the splitter (plain `transfer`) and anyone calls `distribute()`, or the
   operator approves the splitter and calls `depositAndDistribute(amount)` in one step.
2. `distribute()` computes the five shares from all IMD waiting (excluding `pendingBurn`), pays the
   developer, treasury, operations and NFT worker shares immediately and emits `RevenueDistributed`.
   Rounding dust goes to the treasury so the five shares always sum exactly to the revenue.
3. The burn share is sent to `burnSink` in the same call if it is configured. If not, it is kept in
   the contract, recorded in `pendingBurn`, and `BurnDeferred` is emitted. Once the owner sets the
   sink, anyone calls `burnPending()` (or the next `distribute()` does it) and `BurnExecuted` records
   the verified burn amount and destination.

`distribute()` and `burnPending()` are permissionless and have no privileged effect. `distribute()`
reverts with `NothingToDistribute` when no new revenue has arrived; `burnPending()` reverts with
`BurnSinkNotConfigured` until the sink is set and `NothingToBurn` when nothing is pending.

Every owner setter (`setAllocation`, the four recipient setters and `setBurnSink`) first distributes
any revenue already waiting in the contract under the allocation, recipients and sink in force when
it arrived, then writes the new value. A setting therefore applies only to revenue delivered after
it, whatever order the operator's delivery, a third party's `distribute()` and the owner's setter
land in. With nothing waiting, a setter only writes and emits its event.

## Assumptions

- **Revenue is delivered in IMD.** The brief describes SOL revenue funding "IMD purchases" on
  Solana. On Ethereum the operator converts eligible net platform revenue to IMD off chain and
  deposits the IMD, so the "purchase" step happens before deposit and the splitter never swaps.
  This keeps the contract free of venue, slippage and oracle risk. The splitter does not accept ETH.
- **"Eligible net platform revenue" is computed off chain** by the operator, as the brief says: it
  applies to net platform revenue, never trading volume or users' funds. The contract splits what it
  receives; it cannot verify that what it receives is the correct net figure.
- **IMD has no burn function.** The IMD token at the address above exposes `transfer`,
  `transferFrom`, `allowance`, `totalSupply` and `owner`, but no `burn(uint256)` or `burnFrom`
  (checked against its deployed bytecode on 2026-11-14; its verified source is a LayerZero OFT with
  plain OpenZeppelin ERC-20 transfers, no blacklist, pause or transfer fee). A "burn" is therefore a
  transfer to a burn destination the owner configures. This destination is deliberately not
  hard-coded: the IMD project knows which address it treats as its burn address, and the contract
  refuses to invent one. Until it is set, the burn share is held as `pendingBurn` and never lost.
  `BurnExecuted(sink, amount)` and `totalBurned` record transfers to the configured sink; they do
  not by themselves prove the sink is a burn address. Anyone verifying the burn programme checks the
  sink in `BurnSinkUpdated` and `BurnExecuted` against the IMD project's recognised burn address.
  The owner chooses the sink, so the owner could name any address, including its own; that is a
  trust assumption on the requester, stated below, not something the contract can rule out.
- **One payout address.** The brief names a single recipient for fees and payouts, so all four
  paid-out buckets start there. The split is still computed and emitted per bucket so the owner can
  re-point treasury, operations, NFT worker and developer flows separately later.
- **Allocation is owner-adjustable.** The brief fixes the launch allocation and plans a
  sustainability review after three months, so the owner can change the five shares with
  `setAllocation`, which requires them to sum to exactly 10,000 basis points and emits
  `AllocationUpdated`. The launch values are constants (`LAUNCH_*_BPS`).
- **Raydium fees are out of scope.** The brief's note about Raydium platform and creator fees refers
  to a Solana venue; nothing on Ethereum depends on it.

## Deployment parameters

The launch factory deploys both contracts from the built bytecode. Nothing here deploys, broadcasts
or signs.

| Contract | Constructor arguments |
| --- | --- |
| `IMDPumpToken` | none (mints `1000000000000000000000000000` to `msg.sender`, the factory) |
| `IMDPumpRevenueSplitter` | `owner_` = the launch owner (the requester); `payout_` = `0x83027AD9d0D5374335086c539dADD1db983441B0`; `revenueToken_` = IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |

Neither constructor calls another contract, so both deploy on an empty chain. The splitter's owner
must never be the factory or a deployer wallet; `Ownable` is given the owner explicitly.

Launch values decided by the launch, not by this repository: pool paired with IMD, pool fee 12500
(1.25%), tick spacing 60, 88% of the supply seeding the pool at a 2,500 IMD opening market cap,
10% to the swarm's distributor, the remainder to the requester's address. The manifest step writes
`launch.json`; this repository does not.

`script/Deploy.s.sol` is a reference deployment for local and test chains. Its `deploy(Config)`
function is what the tests call; `run()` reads `OWNER`, `PAYOUT` and `REVENUE_TOKEN` from the
environment, each defaulting to the launch values above. On a plain deployment the token's supply
goes to the broadcasting account, because the token mints to `msg.sender`.

## After launch

The owner (the requester) configures the splitter through event-emitting setters.

| Setting | Setter | Set it to | Where it comes from |
| --- | --- | --- | --- |
| Burn destination | `setBurnSink(address)` | The address the IMD project treats as its verified IMD burn address | The IMD project. Required before any burn share leaves the splitter; until then the share accrues in `pendingBurn`, and the sink named first receives everything accrued so far. |
| Developer rewards recipient | `setDeveloper(address)` | The developer's wallet | Starts at the payout address |
| Treasury recipient | `setTreasury(address)` | The IMD ecosystem treasury | Starts at the payout address |
| Operations recipient | `setOperations(address)` | The development and operations wallet | Starts at the payout address |
| NFT worker rewards recipient | `setNftWorkers(address)` | The wallet or contract that pays NFT workers | Starts at the payout address |
| Allocation | `setAllocation(burn, developer, treasury, operations, nftWorkers)` | Basis points summing to 10,000 | The three-month sustainability review. Launch values: 2000, 1500, 2500, 2000, 2000. |

Setters refuse the zero address and the splitter's own address, and each one settles revenue already
waiting before it writes (see Flow above). Ownership moves in two steps only (`transferOwnership`
then `acceptOwnership` by the new owner). `renounceOwnership` is disabled and reverts with
`RenounceDisabled`: an ownerless splitter could never have its burn sink set or corrected, which
would strand the burn share of all past and future revenue, and could never adjust the allocation
after the sustainability review.

## Operational responsibilities

- **Operator:** compute eligible net platform revenue per period, convert it to IMD, deposit it and
  call `distribute()` (or use `depositAndDistribute`). Publish the figures alongside the
  `RevenueDistributed` events so the community can reconcile them.
- **Owner:** set the burn sink promptly after launch, to the IMD project's recognised burn address,
  so the 20% burn share starts leaving the contract; keep recipient addresses current; run the
  sustainability review and announce any new split before calling `setAllocation`. The setters
  settle waiting revenue under the old terms themselves, so no manual `distribute()` is needed
  first. Use a multisig for the owner key, and never try to renounce it (the call is disabled).
- **Anyone:** may call `distribute()` and `burnPending()`. Neither can redirect funds.
- **Recovery:** the owner can recover tokens other than IMD that were sent to the splitter by
  mistake with `recoverToken`. IMD can only leave through distribution and the burn.

## Trust assumptions and security notes

- The owner can re-point revenue flows and change the split for revenue delivered after the change.
  It cannot touch IMDPUMP holders' balances, cannot mint, cannot pause the token, and cannot claw
  back revenue already paid. Revenue already waiting in the splitter when a setter runs is paid
  under the previous settings, so a setter and a permissionless `distribute()` cannot race over it.
- The burn share is the exception: `pendingBurn` (the 20% share of every distribution made while the
  sink was unset) is held until the owner names a sink and then goes to that sink. The owner
  decides where already-accrued burn share goes, and the `BurnExecuted`/`totalBurned` record
  attests the transfer to that owner-chosen destination. Verification that it is a genuine burn
  rests on checking the sink address, not on the event alone.
- Ownership cannot be renounced. Only a two-step transfer moves it.
- A wrongly configured recipient or burn sink loses the IMD sent to it. Setters emit events so a
  mistake is visible before the next distribution.
- All token movements use OpenZeppelin `SafeERC20`; `distribute`, `depositAndDistribute` and
  `burnPending` are guarded by `ReentrancyGuard` and follow checks-effects-interactions.
- `depositAndDistribute` moves tokens only from `msg.sender`.
- No `delegatecall`, `selfdestruct`, proxies, external library calls, `ffi` or filesystem access.
- Tests passing is not an audit. An independent adversarial review is expected before release.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

Pinned with `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"` in `foundry.toml`.
Dependencies are vendored as ordinary files under `lib/` (OpenZeppelin Contracts v5.7.0, forge-std
v1.17.0; see each `VENDORED_VERSION`). Tests read no environment variables and pass in any order.

The test suite covers: token metadata, supply, untaxed transfers (fuzzed), allowance failures,
self-burn and the absence of any admin surface; the splitter's constructor validation, the exact
launch split, rounding, conservation of revenue under the launch and arbitrary allocations (fuzzed),
deferred and immediate burns, every setter's success and failure path, setters settling waiting
revenue under the old terms (and distributing nothing when nothing waits), reentrancy into a
setter's settlement, two-step ownership, the disabled `renounceOwnership`, token recovery, ETH
rejection, a reentrant revenue token and a non-standard (no bool return) token; and the deployment
script's `deploy` function.
