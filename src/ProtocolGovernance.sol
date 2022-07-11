// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./utils/DefaultAccessControl.sol";

/// @notice Contract of the system protocol governance
contract ProtocolGovernance is IProtocolGovernance, ERC165, DefaultAccessControl {
    /// @notice Thrown when a value of a parameter is not valid
    error InvalidValue();

    /// @notice Thrown when a pool address is not valid
    error InvalidPool();

    /// @notice Thrown when a value is incorrectly equal to zero
    error ValueZero();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;

    EnumerableSet.AddressSet private _whitelistedPools;

    ProtocolParams private _protocolParams;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public liquidationThresholdD;

    /// @notice Mapping, returning token capital limit (in token weis)
    mapping(address => uint256) private _tokenCapitalLimit;

    /// @notice Creates a new contract
    /// @param admin Protocol admin
    /// @param maxDebtPerVault Initial max possible debt to a one vault (nominated in MUSD weis)
    constructor(address admin, uint256 maxDebtPerVault) DefaultAccessControl(admin) {
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @inheritdoc IProtocolGovernance
    function protocolParams() external view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    /// @inheritdoc IProtocolGovernance
    function isPoolWhitelisted(address pool) external view returns (bool) {
        return (_whitelistedPools.contains(pool));
    }

    /// @inheritdoc IProtocolGovernance
    function getTokenLimit(address token) external view returns (uint256) {
        uint256 limit = _tokenCapitalLimit[token];
        if (limit == 0) {
            return type(uint256).max;
        }
        return limit;
    }

    /// @inheritdoc IProtocolGovernance
    function whitelistedPool(uint256 i) external view returns (address) {
        return _whitelistedPools.at(i);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165, AccessControlEnumerable)
        returns (bool)
    {
        return (interfaceId == type(IProtocolGovernance).interfaceId) || super.supportsInterface(interfaceId);
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationFee(uint256 liquidationFeeD) external {
        _requireAdmin();
        if (liquidationFeeD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationFeeD = liquidationFeeD;
        emit LiquidationFeeChanged(tx.origin, msg.sender, liquidationFeeD);
    }

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationPremium(uint256 liquidationPremiumD) external {
        _requireAdmin();
        if (liquidationPremiumD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationPremiumD = liquidationPremiumD;
        emit LiquidationPremiumChanged(tx.origin, msg.sender, liquidationPremiumD);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external {
        _requireAdmin();
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
        emit MaxDebtPerVaultChanged(tx.origin, msg.sender, maxDebtPerVault);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external {
        _requireAdmin();
        _protocolParams.minSingleNftCollateral = minSingleNftCollateral;
        emit MinSingleNftCollateralChanged(tx.origin, msg.sender, minSingleNftCollateral);
    }

    /// @inheritdoc IProtocolGovernance
    function setWhitelistedPool(address pool) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert AddressZero();
        }
        _whitelistedPools.add(pool);
        emit WhitelistedPoolSet(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function revokeWhitelistedPool(address pool) external {
        _requireAdmin();
        _whitelistedPools.remove(pool);
        liquidationThresholdD[pool] = 0;
        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function setLiquidationThreshold(address pool, uint256 liquidationThresholdD_) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert AddressZero();
        }
        if (!_whitelistedPools.contains(pool)) {
            revert InvalidPool();
        }
        if (liquidationThresholdD_ > DENOMINATOR) {
            revert InvalidValue();
        }

        liquidationThresholdD[pool] = liquidationThresholdD_;
        emit LiquidationThresholdSet(tx.origin, msg.sender, pool, liquidationThresholdD_);
    }

    /// @inheritdoc IProtocolGovernance
    function setTokenLimit(address token, uint256 newLimit) external {
        _requireAdmin();
        if (token == address(0)) {
            revert AddressZero();
        }

        _tokenCapitalLimit[token] = newLimit;
        emit TokenLimitSet(tx.origin, msg.sender, token, newLimit);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when liquidation fee is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationFeeD The new liquidation fee (multiplied by DENOMINATOR)
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 liquidationFeeD);

    /// @notice Emitted when liquidation premium is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationPremiumD The new liquidation premium (multiplied by DENOMINATOR)
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 liquidationPremiumD);

    /// @notice Emitted when max debt per vault is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param maxDebtPerVault The new max debt per vault (nominated in MUSD weis)
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 maxDebtPerVault);

    /// @notice Emitted when min nft collateral is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param minSingleNftCollateral The new min nft collateral (nominated in MUSD weis)
    event MinSingleNftCollateralChanged(address indexed origin, address indexed sender, uint256 minSingleNftCollateral);

    /// @notice Emitted when liquidation threshold for a specific pool is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The given pool
    /// @param liquidationThresholdD_ The new liquidation threshold (multiplied by DENOMINATOR)
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address pool,
        uint256 liquidationThresholdD_
    );

    /// @notice Emitted when new pool is added to the whitelist
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The new whitelisted pool
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address pool);

    /// @notice Emitted when pool is deleted from the whitelist
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The deleted whitelisted pool
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address pool);

    /// @notice Emitted when token capital limit is set
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param token The token address
    /// @param stagedLimit The new token capital limit
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
}
