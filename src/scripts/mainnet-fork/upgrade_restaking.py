from brownie import Restaking, Staking, interface, accounts, Contract, project, config
from pathlib import Path

# Execution Command Format:
# `brownie run scripts/mainnet-fork/upgrade_restaking.py --network=mainnet-public-fork`


def main():
    deps = project.load(Path.home() / ".brownie" / "packages" / config["dependencies"][0])
    ProxyAdmin = deps.ProxyAdmin
    TransparentUpgradeableProxy = deps.TransparentUpgradeableProxy

    staking = Staking.at("0x4beFa2aA9c305238AA3E0b5D17eB20C045269E9d")
    delayed_withdrawal_router = interface.IDelayedWithdrawalRouter("0x7Fe7E9CC0F274d2435AD5d56D5fa73E47F6A23D8")

    # Upgrade Restaking
    user = accounts.at(accounts[0], True)
    deployer = accounts.at(accounts[1], True)
    proxy_admin_owner = accounts.at("0xAeE017052DF6Ac002647229D58B786E380B9721A", True)

    restaking_proxy = TransparentUpgradeableProxy.at("0x3F4eaCeb930b0Edfa78a1DFCbaE5c5494E6e9850")
    proxy_admin = ProxyAdmin.at("0xa5F2B6AB5B38b88Ba221741b3A189999b4c889C6")

    restaking_impl = Restaking.deploy({'from': deployer})
    proxy_admin.upgrade(restaking_proxy, restaking_impl, {'from': proxy_admin_owner})

    restaking = Contract.from_abi("Restaking", restaking_proxy, Restaking.abi)

    # Test Scenario 1: Call staking.pushBeacon(), which in turn calls restaking.update(), which in turn calls
    # restaking._withdrawEthers() to claim all delayed withdrawals and pod owner balances.
    # All assets mentioned above should be transferred to the staking contract,
    # and pending withdrawals should be updated accordingly.
    total_pod_balance_before = 0
    total_delayed_withdrawal_before = 0
    total_pod_owner_balance_before = 0
    total_pending_withdrawal_before = restaking.getPendingWithdrawalAmount()
    total_pods = restaking.getTotalPods()
    for i in range(total_pods):
        pod = restaking.getPod(i)
        pod_address_obj = accounts.at(pod, True)
        total_pod_balance_before += pod_address_obj.balance()
        pod_owner = restaking.podOwners(i)
        total_pod_owner_balance_before += restaking.balance()
        delayed_withdrawal_list =  delayed_withdrawal_router.getClaimableUserDelayedWithdrawals(pod_owner)
        for j in range(len(delayed_withdrawal_list)):
            total_delayed_withdrawal_before += delayed_withdrawal_list[j]['amount']

    assert total_delayed_withdrawal_before > 0
    assert total_pod_owner_balance_before > 0

    staking_contract_balance_before = staking.balance()
    balance_to_sync = total_delayed_withdrawal_before + total_pod_owner_balance_before
    tx = staking.pushBeacon({'from': user})
    assert 'BalanceSynced' in tx.events
    assert 'Claimed' in tx.events
    assert tx.events['BalanceSynced']['diff'] == balance_to_sync
    assert tx.events['Claimed']['amount'] == total_delayed_withdrawal_before
    assert staking.balance() == staking_contract_balance_before + balance_to_sync
    assert restaking.getPendingWithdrawalAmount() == total_pending_withdrawal_before - balance_to_sync
    assert total_delayed_withdrawal_before == 0
    assert total_pod_owner_balance_before == 0


    # Test Scenario 2: Call staking.pushBeacon() again, which will cause no change to pending withdrawals;
    # namely, no assets should be transferred from any pods to the router.
    total_pending_withdrawal_before = restaking.getPendingWithdrawalAmount()
    assert 'BalanceSynced' in tx.events
    assert 'Claimed' in tx.events
    assert tx.events['BalanceSynced']['diff'] == 0
    assert tx.events['Claimed']['amount'] == 0
    assert restaking.getPendingWithdrawalAmount() == total_pending_withdrawal_before
    assert total_delayed_withdrawal_before == 0
    assert total_pod_owner_balance_before == 0








