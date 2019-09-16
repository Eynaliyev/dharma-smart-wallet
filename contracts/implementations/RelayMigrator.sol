pragma solidity 0.5.11;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/DharmaSmartWalletFactoryV1Interface.sol";
import "../../interfaces/DharmaKeyRegistryInterface.sol";


/**
 * @title RelayMigrator
 * @author 0age
 * @notice This contract will migrate cDAI and cUSDC balances from existing user
 * relay contracts to new smart wallet contracts. It has four distinct phases:
 *  - Phase one: Registration. All existing relay contracts are provided as
 *    arguments to the `register` function. Once all relay contracts have been
 *    registered, the `endRegistration` function is called and the final group
 *    of registered relay contracts is verified by calling
 *    `getTotalRegisteredRelayContracts` and `getRegisteredRelayContract`.
 *  - Phase two: Deployment. This contract will call the Dharma Smart Wallet
 *    factory, supplying the current global signing key set on the Dharma Key
 *    Registry as the user signing key (this means that Dharma will initially be
 *    in full control of each smart wallet). The resultant smart wallet address
 *    will be recorded for each relay contract. Once a smart wallet has been
 *    deployed for each relay contract, the deployment phase will be marked as
 *    ended, and the final group of deployed smart wallets should be verified by
 *    calling `getTotalDeployedSmartWallets` and `getRegisteredRelayContract`
 *    and making sure that each relay contract has a corresponding smart wallet,
 *    then updating that information for each user.
 *  - Phase three: Approval Assignment. Each relay contract will need to call
 *    `executeTransactions` and assign this contract full allowance to transfer
 *    both cDAI and cUSDC ERC20 tokens on it's behalf. This can be done safely,
 *    as there is only one valid recipient for each `transferFrom` sent from the
 *    relay contract: the associated smart wallet. Once this phase is complete,
 *    the `beginMigration` function is called and the token migration can begin.
 *  - Phase four: Migration. The migrator will iterate over each relay contract,
 *    detect the current cDAI and cUSDC token balance on the relay contract, and
 *    transfer it from the relay contract to the smart wallet. If a transfer
 *    does not succeed (for instance, if approvals were not appropriately set),
 *    an event indicating the problematic relay contract will be emitted. Once
 *    all relay contract transfers have been processed, the migrator will begin
 *    again from the start - this enables any missed approvals to be addressed
 *    and any balance changes between the start and the end of the migration to
 *    be brought over as well. Once all users have been successfully migrated
 *    `endMigration` may be called to completely decommission the migrator.
 *
 * After the migration is complete, it is imperative that users set their own
 * signing key by calling `setUserSigningKey` on their smart wallet. Until then,
 * the same signature can be supplied for both the user and for Dharma when
 * performing smart wallet actions (this includes for the initial request to set
 * the user's signing key).
 */
contract RelayMigrator is Ownable {
  using Address for address;

  event MigrationError(
    address cToken, address relayContract, address smartWallet, uint256 balance
  );

  address[] private _relayContracts;

  address[] private _smartWallets;

  mapping(address => bool) private _relayContractRegistered;

  uint256 private _migrationIndex;

  bool public registrationCompleted;

  bool public deploymentCompleted;

  bool public migrationStarted;

  bool public migrationFirstPassCompleted;

  bool public migrationCompleted;

  // The Dharma Smart Wallet Factory will deploy each new smart wallet.
  DharmaSmartWalletFactoryV1Interface internal constant _DHARMA_SMART_WALLET_FACTORY = (
    DharmaSmartWalletFactoryV1Interface(0x8D1e00b000e56d5BcB006F3a008Ca6003b9F0033)
  );

  // The Dharma Key Registry holds a public key for verifying meta-transactions.
  DharmaKeyRegistryInterface internal constant _DHARMA_KEY_REGISTRY = (
    DharmaKeyRegistryInterface(0x00000000006c7f32F0cD1eA4C1383558eb68802D)
  );

  // This contract interfaces with cDai and cUSDC CompoundV2 contracts.
  IERC20 internal constant _CDAI = IERC20(
    0xF5DCe57282A584D2746FaF1593d3121Fcac444dC // mainnet
  );

  IERC20 internal constant _CUSDC = IERC20(
    0x39AA39c021dfbaE8faC545936693aC917d5E7563 // mainnet
  );

  /**
   * @notice In constructor, set the transaction submitter as the owner, set all
   * initial phase flags to false, and set the initial migration index to 0.
   */
  constructor() public {
    _transferOwnership(tx.origin);

    registrationCompleted = false;
    deploymentCompleted = false;
    migrationStarted = false;
    migrationFirstPassCompleted = false;
    migrationCompleted = false;

    _migrationIndex = 0;
  }

  /**
   * @notice Register a group of relay contracts. This function will revert if a
   * supplied relay contract has already been registered. Only the owner may
   * call this function.
   * @param relayContracts address[] An array of relay contract addresses to
   * register.
   */
  function register(address[] calldata relayContracts) external onlyOwner {
    require(
      !registrationCompleted,
      "Cannot register new relay contracts once registration is completed."
    );

    for (uint256 i; i < relayContracts.length; i++) {
      address relayContract = relayContracts[i];
      
      require(
        relayContract.isContract(),
        "Must supply a valid relay contract address."
      );
      require(
        !_relayContractRegistered[relayContract],
        "Relay contract already registered."
      );

      _relayContractRegistered[relayContract] = true;
      _relayContracts.push(relayContract);
    }
  }

  /**
   * @notice End relay contract registration. Only the owner may call this
   * function.
   */
  function endRegistration() external onlyOwner {
    require(!registrationCompleted, "Registration is already completed.");

    registrationCompleted = true;
  }

  /**
   * @notice Deploy smart wallets for each relay, using the global key from the
   * Dharma Key Registry as the initial user signing key. Anyone may call this
   * method once registration is completed until deployments are completed.
   */
  function deploySmartWallets() external {
    require(
      registrationCompleted,
      "Cannot begin smart wallet deployment until registration is completed."
    );

    require(
      !deploymentCompleted,
      "Cannot deploy new smart wallets after deployment is completed."
    );

    address initialKey = _DHARMA_KEY_REGISTRY.getGlobalKey();
    uint256 totalRelayContracts = _relayContracts.length;

    address newSmartWallet;
    while (gasleft() > 500000) {
      newSmartWallet = _DHARMA_SMART_WALLET_FACTORY.newSmartWallet(initialKey);
      _smartWallets.push(newSmartWallet);
      if (_smartWallets.length >= totalRelayContracts) {
        deploymentCompleted = true;
        break;
      }
    }
  }

  /**
   * @notice Begin relay contract migration. Only the owner may call this
   * function, and smart wallet deployment must first be completed.
   */
  function startMigration() external onlyOwner {
    require(
      deploymentCompleted,
      "Cannot start migration until new smart wallet deployment is completed."
    );

    require(!migrationStarted, "Migration has already started.");

    migrationStarted = true;
  }

  /**
   * @notice Migrate cDAI and cUSDC token balances from each relay contract to
   * the corresponding smart wallet. Anyone may call this method once migration
   * has started until deployments are completed.
   */
  function migrateRelayContractsToSmartWallets() external {
    require(
      migrationStarted,
      "Cannot begin relay contract migration until migration has started."
    );

    require(!migrationCompleted, "Migration is fully completed.");

    uint256 totalRelayContracts = _relayContracts.length;

    address relayContract;
    address smartWallet;
    uint256 balance;
    bool ok;

    for (uint256 i = _migrationIndex; i < totalRelayContracts; i++) {
      if (gasleft() < 200000) {
        _migrationIndex = i;
        return;
      }

      relayContract = _relayContracts[i];
      smartWallet = _smartWallets[i];

      balance = _CDAI.balanceOf(relayContract);

      if (balance > 0) {
        (ok, ) = address(_CDAI).call(abi.encodeWithSelector(
          _CDAI.transferFrom.selector, relayContract, smartWallet, balance
        ));

        // Emit a corresponding event if the transfer failed.
        if (!ok) {
          emit MigrationError(
            address(_CDAI), relayContract, smartWallet, balance
          );
        }
      }

      balance = _CUSDC.balanceOf(relayContract);

      if (balance > 0) {
        (ok, ) = address(_CUSDC).call(abi.encodeWithSelector(
          _CUSDC.transferFrom.selector, relayContract, smartWallet, balance
        ));

        // Emit a corresponding event if the transfer failed.
        if (!ok) {
          emit MigrationError(
            address(_CUSDC), relayContract, smartWallet, balance
          );
        }
      }
    }

    migrationFirstPassCompleted = true;
    _migrationIndex = 0;
  }

  /**
   * @notice End the migration and decommission the migrator. Only the owner may
   * call this function, and a full first pass must first be completed.
   */
  function endMigration() external onlyOwner {
    require(
      migrationFirstPassCompleted,
      "Cannot end migration until at least one full pass is completed."
    );

    require(!migrationCompleted, "Migration has already completed.");

    migrationCompleted = true;
  }

  function getTotalRegisteredRelayContracts() external view returns (uint256) {
    return _relayContracts.length;
  }

  function getTotalDeployedSmartWallets() external view returns (uint256) {
    return _smartWallets.length;
  }

  function getRegisteredRelayContract(
    uint256 index
  ) external view returns (address relayContract, address smartWallet) {
    relayContract = _relayContracts[index];
    smartWallet = _smartWallets[index];
  } 
}