# IMD PUMP test coverage

The added suites extend the original tests without changing production contracts or configuration.
They use the vendored Foundry and OpenZeppelin libraries and require no network access.

| Suite | Main properties |
| --- | --- |
| `IMDPumpTokenProperties.t.sol` | Untaxed round trips and launch transfers; zero, one-unit, full-supply and maximum-value edges; finite/infinite allowances, revocation, failed-call rollback, holder-only burns. |
| `IMDPumpRevenueProperties.t.sol` | Allocation corners and rounding bounds; pending burns versus fresh revenue; recipient and ownership transitions; false-returning, reverting and no-return tokens; rollback at every payout position; cross-function reentry; every setter settling waiting revenue under the old terms (and nothing when nothing waits), rejected input settling nothing, one-wei front-running of a re-point, reentry from a setter's settlement, and the disabled `renounceOwnership`. |
| `invariant/IMDPumpTokenInvariant.t.sol` | Four actors transfer, approve, spend, burn and attempt invalid operations. An independent ledger tracks every balance and allowance. Remaining supply plus recorded holder burns always equals the constructor supply. |
| `invariant/IMDPumpRevenueInvariant.t.sol` | Three operators donate, deposit, distribute and flush burns while owners, allocations and recipients change. Received revenue equals paid balances plus pending burns plus undistributed revenue. Each setter's settlement of waiting revenue is checked against the rates, recipients and sink in force before it; owner renounce attempts must revert with `RenounceDisabled`. Stray-token recovery has a separate ledger. Every sequence must also be able to finish distribution. |
| `IMDPumpWalletGas.t.sol` | The supplied `helpers/WalletGas.sol` compares events and return data at the minimum successful gas limit and with gas to spare for `depositAndDistribute`, `distribute`, `burnPending`, `recoverToken`, and the setters when they settle waiting revenue. Includes deferred/immediate burns, shared recipients, storage-clearing transfers, finite/infinite allowances, and no-return tokens. |

The discovery review used the supplied conservation, state-transition, rounding, adversarial and
token-specific guides. Conservation and supply properties are accounting identities. Authorization,
recipient and burn transitions follow the public interfaces in `src/IMDPumpToken.sol` and
`src/IMDPumpRevenueSplitter.sol`. Rounding checks constrain actual credits to less than one minor
unit below each non-treasury entitlement; the treasury receives the combined remainders.

Each invariant campaign runs 256 sequences of 128 calls. Only explicit handler selectors are
targeted. Unexpected successes, reverts, return values and payout discrepancies set a persistent
failure flag, so ignoring ordinary handler reverts cannot silently turn an assertion into a pass.
The new stateless fuzz properties run 1,000 examples each, with bounded inputs and pinned unit edges.

Revenue fixtures model a plain ERC-20. Burn destinations are isolated test accounts used to check
delivery and accounting; these tests do not certify a real destination as irrecoverable. Eligibility
of platform revenue and conversion into IMD happen outside these contracts. No real RPC endpoint,
key, deployment, or production burn destination is needed by this suite.

To reproduce the required checks while keeping generated artifacts in disposable scratch space:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x290422ce681decd0699251077b934dd6da57b2987be015f450b761d0b438c05e forge test --out test/scratch/out --cache-path test/scratch/cache
```

Reported rather than asserted (see `.imd-findings.json`): because every setter settles waiting
revenue first, a recipient or sink whose transfer reverts cannot be re-pointed while any revenue is
waiting, and anyone can keep one unit waiting. The suite does not assert that behaviour.
