# Security policy

This repository is a **local teaching lab**. `LendingPoolVulnerable` is intentionally incorrect. It is not a production protocol.

## Authorized use only

- Run `forge test` on this repo, on a local Foundry EVM.
- Fork tests use public Ethereum state as **token semantics** for the teaching pool. They do not target third-party vaults.
- Do not use the PoC against third-party deployments unless you have written authorization.

## Reporting a problem in *this* lab

If an invariant on the **fixed** pool does not actually hold, email **dersefurkan32@gmail.com** with `forge` version and the command.

Do not open a public issue for a vulnerability in a client system.
