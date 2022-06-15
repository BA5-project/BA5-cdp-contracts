// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/external/chainlink/IAggregatorV3.sol";
import "../libraries/external/FullMath.sol";
import "../libraries/ExceptionsLibrary.sol";
import "../libraries/CommonLibrary.sol";
import "../utils/DefaultAccessControl.sol";
import "../interfaces/oracles/IOracle.sol";

/// @notice Contract for getting chainlink data
contract ChainlinkOracle is IOracle, DefaultAccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    int256 constant DECIMALS = 18;

    mapping(address => address) public oraclesIndex;
    mapping(address => int256) public decimalsIndex;
    EnumerableSet.AddressSet private _tokens;

    constructor(
        address[] memory tokens,
        address[] memory oracles,
        address admin
    ) DefaultAccessControl(admin) {
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  EXTERNAL, VIEW  ------------------------------

    function hasOracle(address token) external view returns (bool) {
        return _tokens.contains(token);
    }

    function supportedTokens() external view returns (address[] memory) {
        return _tokens.values();
    }

    /// @inheritdoc IOracle
    function price(address token) external view returns (uint256 priceX96) {
        priceX96 = 0;
        IAggregatorV3 chainlinkOracle = IAggregatorV3(oraclesIndex[token]);
        if (address(chainlinkOracle) == address(0)) {
            return priceX96;
        }
        uint256 price0;
        uint256 price1 = 1;
        bool success;
        (success, price0) = _queryChainlinkOracle(chainlinkOracle0);
        if (!success) {
            return priceX96;
        }

        int256 decimals0 = decimalsIndex[token];
        if (DECIMALS > decimals0) {
            price1 *= 10**(uint256(DECIMALS - decimals0));
        } else if (decimals0 > decimals1) {
            price0 *= 10**(uint256(decimals0 - DECIMALS));
        }
        priceX96 = FullMath.mulDiv(price0, CommonLibrary.Q96, price1);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId) || interfaceId == type(IOracle).interfaceId;
    }

    // -------------------------  EXTERNAL, MUTATING  ------------------------------

    function addChainlinkOracles(address[] memory tokens, address[] memory oracles) external {
        _requireAdmin();
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    function _queryChainlinkOracle(IAggregatorV3 oracle) internal view returns (bool success, uint256 answer) {
        try oracle.latestRoundData() returns (uint80, int256 ans, uint256, uint256, uint80) {
            return (true, uint256(ans));
        } catch (bytes memory) {
            return (false, 0);
        }
    }

    // -------------------------  INTERNAL, MUTATING  ------------------------------

    function _addChainlinkOracles(address[] memory tokens, address[] memory oracles) internal {
        require(tokens.length == oracles.length, ExceptionsLibrary.INVALID_VALUE);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address oracle = oracles[i];
            _tokens.add(token);
            oraclesIndex[token] = oracle;
            decimalsIndex[token] = int256(
                -int8(IERC20Metadata(token).decimals()) - int8(IAggregatorV3(oracle).decimals())
            );
        }
        emit OraclesAdded(tx.origin, msg.sender, tokens, oracles);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when new Chainlink oracle is added
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokens Tokens added
    /// @param oracles Orecles added for the tokens
    event OraclesAdded(address indexed origin, address indexed sender, address[] tokens, address[] oracles);
}
