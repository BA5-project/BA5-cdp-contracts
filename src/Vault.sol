// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IMUSD.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./interfaces/oracles/IOracle.sol";
import "./libraries/external/FullMath.sol";
import "./proxy/EIP1967Admin.sol";
import "./utils/VaultAccessControl.sol";
import "./interfaces/IVaultRegistry.sol";
import "./interfaces/oracles/INFTOracle.sol";
import "./interfaces/external/univ3/INonfungiblePositionManager.sol";
import "forge-std/console2.sol";

/// @notice Contract of the system vault manager
contract Vault is EIP1967Admin, VaultAccessControl, IERC721Receiver {
    /// @notice Thrown when a vault is private and a depositor is not allowed
    error AllowList();

    /// @notice Thrown when a value of a deposited NFT is less than min single nft capital (set in governance)
    error CollateralUnderflow();

    /// @notice Thrown when a vault has already been initialized
    error Initialized();

    /// @notice Thrown when a pool of NFT is not in the whitelist
    error InvalidPool();

    /// @notice Thrown when a value of a stabilization fee is incorrect
    error InvalidValue();

    /// @notice Thrown when a vault id does not exist
    error InvalidVault();

    /// @notice Thrown when no Chainlink oracle is added for one of tokens of a deposited Uniswap V3 NFT
    error MissingOracle();

    /// @notice Thrown when the nft limit for one vault would have been exceeded after the deposit
    error NFTLimitExceeded();

    /// @notice Thrown when the system is paused
    error Paused();

    /// @notice Thrown when a position is healthy
    error PositionHealthy();

    /// @notice Thrown when a position is unhealthy
    error PositionUnhealthy();

    /// @notice Thrown when the VaultRegistry has already been set
    error VaultRegistryAlreadySet();

    /// @notice Thrown when a vault is tried to be closed and debt has not been paid yet
    error UnpaidDebt();

    /// @notice Thrown when the vault debt limit (which's set in governance) would been exceeded after a deposit
    error DebtLimitExceeded();

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant YEAR = 365 * 24 * 3600;

    /// @notice UniswapV3 position manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Protocol governance, which controls this specific Vault
    IProtocolGovernance public immutable protocolGovernance;

    /// @notice Oracle for price estimations
    INFTOracle public immutable oracle;

    /// @notice Mellow Stable Token
    IMUSD public immutable token;

    /// @notice Vault fees treasury address
    address public immutable treasury;

    /// @notice Vault Registry
    IVaultRegistry public vaultRegistry;

    /// @notice State variable, which shows if Vault is initialized or not
    bool public isInitialized;

    /// @notice State variable, which shows if Vault is paused or not
    bool public isPaused;

    /// @notice State variable, which shows if Vault is public or not
    bool public isPublic;

    /// @notice Address set, containing only accounts, which are allowed to make deposits
    EnumerableSet.AddressSet private _depositorsAllowlist;

    /// @notice Mapping, returning set of all nfts, managed by vault
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;

    /// @notice Mapping, returning debt by vault id (in MUSD weis)
    mapping(uint256 => uint256) public vaultDebt;

    /// @notice Mapping, returning total accumulated stabilising fees by vault id (which are due to be paid)
    mapping(uint256 => uint256) public stabilisationFeeVaultSnapshot;

    /// @notice Mapping, returning id of a vault, that storing specific nft
    mapping(uint256 => uint256) public vaultIdByNft;

    /// @notice Mapping, returning timestamp of latest debt fee update, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _stabilisationFeeVaultSnapshotTimestamp;

    /// @notice Mapping, returning last cumulative sum of time-weighted debt fees by vault id, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _globalStabilisationFeePerUSDVaultSnapshotD;

    /// @notice State variable, returning vaults quantity (gets incremented after opening a new vault)
    uint256 public vaultCount = 0;

    /// @notice State variable, returning current stabilisation fee (multiplied by DENOMINATOR)
    uint256 public stabilisationFeeRateD;

    /// @notice State variable, returning latest timestamp of stabilisation fee update
    uint256 public globalStabilisationFeePerUSDSnapshotTimestamp;

    /// @notice State variable, meaning time-weighted cumulative stabilisation fee
    uint256 public globalStabilisationFeePerUSDSnapshotD = 0;

    /// @notice Creates a new contract
    /// @param positionManager_ UniswapV3 position manager
    /// @param oracle_ Oracle
    /// @param protocolGovernance_ UniswapV3 protocol governance
    /// @param treasury_ Vault fees treasury
    /// @param token_ Address of token
    constructor(
        INonfungiblePositionManager positionManager_,
        INFTOracle oracle_,
        IProtocolGovernance protocolGovernance_,
        address treasury_,
        address token_
    ) {
        if (
            address(positionManager_) == address(0) ||
            address(oracle_) == address(0) ||
            address(protocolGovernance_) == address(0) ||
            address(treasury_) == address(0) ||
            address(token_) == address(0)
        ) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        oracle = oracle_;
        protocolGovernance = protocolGovernance_;
        treasury = treasury_;
        token = IMUSD(token_);
        isInitialized = true;
    }

    /// @notice Initialized a new contract.
    /// @param admin Protocol admin
    /// @param stabilisationFee_ MUSD initial stabilisation fee
    function initialize(address admin, uint256 stabilisationFee_) external {
        if (isInitialized) {
            revert Initialized();
        }

        if (admin == address(0)) {
            revert AddressZero();
        }

        if (stabilisationFee_ > DENOMINATOR) {
            revert InvalidValue();
        }

        _setupRole(OPERATOR, admin);
        _setupRole(ADMIN_ROLE, admin);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ADMIN_DELEGATE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR, ADMIN_DELEGATE_ROLE);

        // initial value
        stabilisationFeeRateD = stabilisationFee_;
        globalStabilisationFeePerUSDSnapshotTimestamp = block.timestamp;
        isInitialized = true;
    }

    // -------------------   PUBLIC, VIEW   -------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC721Receiver).interfaceId == interfaceId;
    }

    /// @notice Calculate adjusted collateral for a given vault (token capitals of each specific collateral in the vault in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return uint256 Adjusted collateral
    function calculateVaultAdjustedCollateral(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        uint256[] memory nfts = _vaultNfts[vaultId].values();

        IProtocolGovernance protocolGovernance_ = protocolGovernance;

        for (uint256 i = 0; i < nfts.length; ++i) {
            (, uint256 price, address pool) = oracle.price(nfts[i]);
            uint256 liquidationThresholdD = protocolGovernance_.liquidationThresholdD(pool);
            result += FullMath.mulDiv(price, liquidationThresholdD, DENOMINATOR);
        }
        return result;
    }

    /// @notice Get global time-weighted stabilisation fee per USD (multiplied by DENOMINATOR)
    /// @return uint256 Global stabilisation fee per USD (multiplied by DENOMINATOR)
    function globalStabilisationFeePerUSDD() public view returns (uint256) {
        return
            globalStabilisationFeePerUSDSnapshotD +
            (stabilisationFeeRateD * (block.timestamp - globalStabilisationFeePerUSDSnapshotTimestamp)) /
            YEAR;
    }

    /// @notice Get total debt for a given vault by id (including fees)
    /// @param vaultId Id of the vault
    /// @return uint256 Total debt value (in MUSD weis)
    function getOverallDebt(uint256 vaultId) public view returns (uint256) {
        uint256 currentDebt = vaultDebt[vaultId];
        return currentDebt + stabilisationFeeVaultSnapshot[vaultId] + _accruedStabilisationFee(vaultId, currentDebt);
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Get all NFTs, managed by vault with given id
    /// @param vaultId Id of the vault
    /// @return uint256[] Array of NFTs, managed by vault
    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory) {
        return _vaultNfts[vaultId].values();
    }

    /// @notice Get all verified depositors
    /// @return address[] Array of verified depositors
    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Open a new Vault
    /// @return vaultId Id of the new vault
    function openVault() public onlyUnpaused returns (uint256 vaultId) {
        if (!isPublic && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        vaultId = vaultCount + 1;
        vaultCount = vaultId;

        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();

        vaultRegistry.mint(msg.sender, vaultId);

        emit VaultOpened(msg.sender, vaultId);
    }

    /// @notice Close a vault
    /// @param vaultId Id of the vault
    /// @param collateralRecipient The address of collateral recipient
    function closeVault(uint256 vaultId, address collateralRecipient) external onlyUnpaused {
        _requireVaultOwner(vaultId);

        if (vaultDebt[vaultId] + stabilisationFeeVaultSnapshot[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, collateralRecipient);

        emit VaultClosed(msg.sender, vaultId);
    }

    /// @notice Deposit collateral to a given vault
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
    function depositCollateral(uint256 vaultId, uint256 nft) public {
        positionManager.safeTransferFrom(msg.sender, address(this), nft, abi.encode(vaultId));
    }

    /// @notice Withdraw collateral from a given vault
    /// @param nft UniV3 NFT to be withdrawn
    function withdrawCollateral(uint256 nft) external {
        uint256 vaultId = vaultIdByNft[nft];
        _requireVaultOwner(vaultId);

        _vaultNfts[vaultId].remove(nft);

        positionManager.transferFrom(address(this), msg.sender, nft);

        // checking that health factor is more or equal than 1
        if (calculateVaultAdjustedCollateral(vaultId) < getOverallDebt(vaultId)) {
            revert PositionUnhealthy();
        }

        delete vaultIdByNft[nft];

        emit CollateralWithdrew(msg.sender, vaultId, nft);
    }

    /// @notice Mint debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be mited
    function mintDebt(uint256 vaultId, uint256 amount) public onlyUnpaused {
        _requireVaultOwner(vaultId);
        _updateVaultStabilisationFee(vaultId);

        token.mint(msg.sender, amount);
        vaultDebt[vaultId] += amount;
        uint256 overallVaultDebt = stabilisationFeeVaultSnapshot[vaultId] + vaultDebt[vaultId];

        if (calculateVaultAdjustedCollateral(vaultId) < overallVaultDebt) {
            revert PositionUnhealthy();
        }

        if (protocolGovernance.protocolParams().maxDebtPerVault < overallVaultDebt) {
            revert DebtLimitExceeded();
        }

        emit DebtMinted(msg.sender, vaultId, amount);
    }

    /// @notice Burn debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be burned
    function burnDebt(uint256 vaultId, uint256 amount) external {
        _requireVaultOwner(vaultId);
        _updateVaultStabilisationFee(vaultId);

        uint256 currentVaultDebt = vaultDebt[vaultId];
        uint256 overallDebt = stabilisationFeeVaultSnapshot[vaultId] + currentVaultDebt;
        amount = (amount < overallDebt) ? amount : overallDebt;
        uint256 overallAmount = amount;

        if (amount > currentVaultDebt) {
            uint256 burningFeeAmount = amount - currentVaultDebt;
            token.mint(treasury, burningFeeAmount);
            stabilisationFeeVaultSnapshot[vaultId] -= burningFeeAmount;
            amount -= burningFeeAmount;
        }

        token.transferFrom(msg.sender, address(this), overallAmount);
        token.burn(overallAmount);
        vaultDebt[vaultId] -= amount;

        emit DebtBurned(msg.sender, vaultId, overallAmount);
    }

    /// @notice Liquidate a vault
    /// @param vaultId Id of the vault subject to liquidation
    function liquidate(uint256 vaultId) external {
        uint256 overallDebt = getOverallDebt(vaultId);
        if (calculateVaultAdjustedCollateral(vaultId) >= overallDebt) {
            revert PositionHealthy();
        }

        address owner = vaultRegistry.ownerOf(vaultId);

        uint256 vaultAmount = 0;

        uint256[] memory nfts = _vaultNfts[vaultId].values();

        for (uint256 i = 0; i < nfts.length; ++i) {
            (, uint256 positionAmount, ) = oracle.price(nfts[i]);
            vaultAmount += positionAmount;
        }

        uint256 returnAmount = FullMath.mulDiv(
            DENOMINATOR - protocolGovernance.protocolParams().liquidationPremiumD,
            vaultAmount,
            DENOMINATOR
        );
        uint256 currentDebt = vaultDebt[vaultId];
        if (returnAmount < currentDebt) {
            returnAmount = currentDebt;
        }
        token.transferFrom(msg.sender, address(this), returnAmount);

        token.burn(currentDebt);

        uint256 daoReceiveAmount = overallDebt -
            currentDebt +
            FullMath.mulDiv(protocolGovernance.protocolParams().liquidationFeeD, vaultAmount, DENOMINATOR);
        if (daoReceiveAmount > returnAmount - currentDebt) {
            daoReceiveAmount = returnAmount - currentDebt;
        }
        token.transfer(owner, returnAmount - currentDebt - daoReceiveAmount);
        token.transfer(treasury, daoReceiveAmount);

        _closeVault(vaultId, msg.sender);

        emit VaultLiquidated(msg.sender, vaultId);
    }

    function mintDebtFromScratch(uint256 nft, uint256 amount) external returns (uint256 vaultId) {
        vaultId = openVault();
        depositCollateral(vaultId, nft);
        mintDebt(vaultId, amount);
    }

    function depositAndMint(
        uint256 vaultId,
        uint256 nft,
        uint256 amount
    ) external {
        depositCollateral(vaultId, nft);
        mintDebt(vaultId, amount);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) external onlyUnpaused returns (bytes4) {
        if (msg.sender != address(positionManager)) {
            revert Forbidden();
        }
        uint256 vaultId = abi.decode(data, (uint256));

        _depositCollateral(from, vaultId, tokenId);

        return this.onERC721Received.selector;
    }

    /// @notice Set a new vault registry
    /// @param vaultRegistry_ The new vault registry address
    function setVaultRegistry(IVaultRegistry vaultRegistry_) external onlyVaultAdmin {
        if (address(vaultRegistry) != address(0)) {
            revert VaultRegistryAlreadySet();
        }

        if (address(vaultRegistry_) == address(0)) {
            revert AddressZero();
        }

        vaultRegistry = vaultRegistry_;

        emit VaultRegistrySet(tx.origin, msg.sender, address(vaultRegistry_));
    }

    /// @notice Pause the system
    function pause() external onlyAtLeastOperator {
        isPaused = true;

        emit SystemPaused(tx.origin, msg.sender);
    }

    /// @notice Unpause the system
    function unpause() external onlyVaultAdmin {
        isPaused = false;

        emit SystemUnpaused(tx.origin, msg.sender);
    }

    /// @notice Make the system private
    function makePrivate() external onlyVaultAdmin {
        isPublic = false;

        emit SystemPrivate(tx.origin, msg.sender);
    }

    /// @notice Make the system public
    function makePublic() external onlyVaultAdmin {
        isPublic = true;

        emit SystemPublic(tx.origin, msg.sender);
    }

    /// @notice Add an array of new depositors to the allow list
    /// @param depositors Array of new depositors
    function addDepositorsToAllowlist(address[] calldata depositors) external onlyVaultAdmin {
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.add(depositors[i]);
        }
    }

    /// @notice Remove an array of depositors from the allow list
    /// @param depositors Array of new depositors
    function removeDepositorsFromAllowlist(address[] calldata depositors) external onlyVaultAdmin {
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.remove(depositors[i]);
        }
    }

    /// @notice Update stabilisation fee (multiplied by DENOMINATOR) and calculate global stabilisation fee per USD up to current timestamp using previous stabilisation fee
    /// @param stabilisationFeeRateD_ New stabilisation fee multiplied by DENOMINATOR
    function updateStabilisationFeeRate(uint256 stabilisationFeeRateD_) external onlyVaultAdmin {
        if (stabilisationFeeRateD_ > DENOMINATOR) {
            revert InvalidValue();
        }

        uint256 delta = block.timestamp - globalStabilisationFeePerUSDSnapshotTimestamp;
        globalStabilisationFeePerUSDSnapshotD += (delta * stabilisationFeeRateD) / YEAR;

        stabilisationFeeRateD = stabilisationFeeRateD_;
        globalStabilisationFeePerUSDSnapshotTimestamp = block.timestamp;

        emit StabilisationFeeUpdated(tx.origin, msg.sender, stabilisationFeeRateD_);
    }

    // -------------------  INTERNAL, VIEW  -----------------------

    /// @notice Check if the caller is the vault owner
    /// @param vaultId Vault id
    function _requireVaultOwner(uint256 vaultId) internal view {
        if (vaultRegistry.ownerOf(vaultId) != msg.sender) {
            revert Forbidden();
        }
    }

    /// @notice Check if the system is unpaused
    function _requireUnpaused() internal view {
        if (isPaused) {
            revert Paused();
        }
    }

    /// @notice Calculate accured stabilisation fee for a given vault (in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return uint256 Accrued stablisation fee of the vault (in MUSD weis)
    function _accruedStabilisationFee(uint256 vaultId, uint256 currentVaultDebt) internal view returns (uint256) {
        uint256 deltaGlobalStabilisationFeeD = globalStabilisationFeePerUSDD() -
            _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];
        return FullMath.mulDiv(currentVaultDebt, deltaGlobalStabilisationFeeD, DENOMINATOR);
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    /// @notice Completes deposit of a collateral to vault
    /// @param caller Caller address
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
    function _depositCollateral(
        address caller,
        uint256 vaultId,
        uint256 nft
    ) internal {
        if (!isPublic && !_depositorsAllowlist.contains(caller)) {
            revert AllowList();
        }

        if (protocolGovernance.protocolParams().maxNftsPerVault <= _vaultNfts[vaultId].length()) {
            revert NFTLimitExceeded();
        }

        if (vaultRegistry.ownerOf(vaultId) == address(0)) {
            revert InvalidVault();
        }

        (bool success, uint256 positionAmount, address pool) = oracle.price(nft);

        if (!success) {
            revert MissingOracle();
        }

        if (!protocolGovernance.isPoolWhitelisted(pool)) {
            revert InvalidPool();
        }

        console2.log(positionAmount);
        console2.log(protocolGovernance.protocolParams().minSingleNftCollateral);
        if (positionAmount < protocolGovernance.protocolParams().minSingleNftCollateral) {
            revert CollateralUnderflow();
        }

        vaultIdByNft[nft] = vaultId;
        _vaultNfts[vaultId].add(nft);

        emit CollateralDeposited(caller, vaultId, nft);
    }

    /// @notice Close a vault (internal)
    /// @param vaultId Id of the vault
    /// @param nftsRecipient Address to receive nft of the positions in the closed vault
    function _closeVault(uint256 vaultId, address nftsRecipient) internal {
        uint256[] memory nfts = _vaultNfts[vaultId].values();
        INonfungiblePositionManager positionManager_ = positionManager;

        for (uint256 i = 0; i < nfts.length; ++i) {
            uint256 nft = nfts[i];

            delete vaultIdByNft[nft];

            positionManager_.transferFrom(address(this), nftsRecipient, nft);
        }

        delete vaultDebt[vaultId];
        delete stabilisationFeeVaultSnapshot[vaultId];
        delete _vaultNfts[vaultId];
        delete _stabilisationFeeVaultSnapshotTimestamp[vaultId];
        delete _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];
    }

    /// @notice Update stabilisation fee for a given vault (in MUSD weis)
    /// @param vaultId Id of the vault
    function _updateVaultStabilisationFee(uint256 vaultId) internal {
        uint256 currentVaultDebt = vaultDebt[vaultId];
        if (block.timestamp == _stabilisationFeeVaultSnapshotTimestamp[vaultId]) {
            return;
        }

        stabilisationFeeVaultSnapshot[vaultId] += _accruedStabilisationFee(vaultId, currentVaultDebt);
        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();
    }

    // -----------------------  MODIFIERS  --------------------------

    modifier onlyVaultAdmin() {
        _requireAdmin();
        _;
    }

    modifier onlyAtLeastOperator() {
        _requireAtLeastOperator();
        _;
    }

    modifier onlyUnpaused() {
        _requireUnpaused();
        _;
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when a new vault is opened
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultOpened(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is liquidated
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultLiquidated(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is closed
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultClosed(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a collateral is deposited
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralDeposited(address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a collateral is withdrawn
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralWithdrew(address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a debt is minted
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtMinted(address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when a debt is burnt
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtBurned(address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when the stabilisation fee is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param stabilisationFee New stabilisation fee
    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);

    /// @notice Emitted when the VaultRegistry is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultRegistryAddress New vaultRegistry address
    event VaultRegistrySet(address indexed origin, address indexed sender, address vaultRegistryAddress);

    /// @notice Emitted when the system is set to paused
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPaused(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to unpaused
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemUnpaused(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to private
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPrivate(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to public
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPublic(address indexed origin, address indexed sender);
}
