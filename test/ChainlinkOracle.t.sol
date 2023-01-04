// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../lib/forge-std/src/Test.sol";
import "./configs/PolygonConfigContract.sol";
import "./SetupContract.sol";
import "../src/Vault.sol";
import "./mocks/MUSD.sol";
import "./mocks/MockOracle.sol";
import "../src/interfaces/external/univ3/IUniswapV3Factory.sol";
import "../src/interfaces/external/univ3/IUniswapV3Pool.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./utils/Utilities.sol";
import "./mocks/MockChainlinkOracle.sol";

contract ChainlinkOracleTest is Test, SetupContract, Utilities {
    event OraclesAdded(
        address indexed origin,
        address indexed sender,
        address[] tokens,
        address[] oracles,
        uint48[] heartbeats
    );
    event ValidPeriodUpdated(address indexed origin, address indexed sender, uint256 validPeriod);
    event PricePosted(
        address indexed origin,
        address indexed sender,
        address token,
        uint256 newPriceX96,
        uint48 fallbackUpdatedAt
    );

    uint256 YEAR = 365 * 24 * 60 * 60;

    ChainlinkOracle oracle;

    function setUp() public {
        oracle = deployChainlink();
    }

    // hasOracle

    function testHasOracleExistedToken() public {
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(oracle.hasOracle(tokens[i]));
        }
    }

    function testHasOracleNonExistedToken() public {
        assertFalse(oracle.hasOracle(getNextUserAddress()));
    }

    // addChainlinkOracles

    function testAddChainlinkOraclesSuccess() public {
        address[] memory emptyTokens = new address[](0);
        address[] memory emptyOracles = new address[](0);
        uint48[] memory emptyHeartbeats = new uint48[](0);
        ChainlinkOracle currentOracle = new ChainlinkOracle(emptyTokens, emptyOracles, emptyHeartbeats, 3600);

        currentOracle.addChainlinkOracles(tokens, chainlinkOracles, heartbeats);

        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(currentOracle.hasOracle(tokens[i]));
        }
    }

    function testAddChainlinkOraclesEmit() public {
        address[] memory emptyTokens = new address[](0);
        address[] memory emptyOracles = new address[](0);
        uint48[] memory emptyHeartbeats = new uint48[](0);
        ChainlinkOracle currentOracle = new ChainlinkOracle(emptyTokens, emptyOracles, emptyHeartbeats, 3600);

        vm.expectEmit(false, true, false, true);
        emit OraclesAdded(getNextUserAddress(), address(this), tokens, chainlinkOracles, heartbeats);
        currentOracle.addChainlinkOracles(tokens, chainlinkOracles, heartbeats);
    }

    function testAddChainlinkOraclesWhenInvalidValue() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = wbtc;
        address[] memory currentOracles = new address[](0);

        vm.expectRevert(ChainlinkOracle.InvalidLength.selector);
        oracle.addChainlinkOracles(currentTokens, currentOracles, heartbeats);
    }

    // price

    function testPrice() public {
        (bool wethSuccess, uint256 wethPriceX96) = oracle.price(weth);
        (bool usdcSuccess, uint256 usdcPriceX96) = oracle.price(usdc);
        (bool wbtcSuccess, uint256 wbtcPriceX96) = oracle.price(wbtc);
        assertEq(wethSuccess, true);
        assertEq(usdcSuccess, true);
        assertEq(wbtcSuccess, true);
        assertApproxEqual(1500, wethPriceX96 >> 96, 500);
        assertApproxEqual(10**12, usdcPriceX96 >> 96, 50);
        assertApproxEqual(20000 * (10**10), wbtcPriceX96 >> 96, 500);
    }

    function testPriceReturnsZeroForNonSetToken() public {
        (bool success, uint256 priceX96) = oracle.price(getNextUserAddress());
        assertEq(success, false);
        assertEq(priceX96, 0);
    }

    function testOracleNotAddedForBrokenOracle() public {
        MockChainlinkOracle mockOracle = new MockChainlinkOracle();

        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = address(mockOracle);
        uint48[] memory currentHeartbeats = new uint48[](1);
        currentHeartbeats[0] = 1500;

        vm.expectRevert(ChainlinkOracle.InvalidOracle.selector);
        oracle.addChainlinkOracles(currentTokens, currentOracles, currentHeartbeats);
    }

    // setValidPeriod

    function testSetValidPeriodSuccess() public {
        oracle.setValidPeriod(500);
        assertEq(oracle.validPeriod(), 500);
    }

    function testSetValidPeriodEmit() public {
        vm.expectEmit(false, true, false, true);
        oracle.setValidPeriod(500);
        emit ValidPeriodUpdated(getNextUserAddress(), address(this), 500);
    }

    function testSetValidPeriodWhenNotOwner() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setValidPeriod(500);
    }

    // setUnderlyingPriceX96

    function testSetUnderlyingPriceX96Success() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = chainlinkOracles[0];
        uint48[] memory currentHeartbeats = new uint48[](1);
        currentHeartbeats[0] = 1500;

        oracle.addChainlinkOracles(currentTokens, currentOracles, currentHeartbeats);

        vm.warp(block.timestamp + YEAR);

        (bool success, uint256 priceX96) = oracle.price(ape);
        assertEq(success, false);
        oracle.setUnderlyingPriceX96(ape, 30 << 96, uint48(block.timestamp));
        (success, priceX96) = oracle.price(ape);
        assertEq(success, true);
        assertEq(priceX96, 30 << 96);
    }

    function testSetUnderlyingPriceX96Emit() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = chainlinkOracles[0];
        uint48[] memory currentHeartbeats = new uint48[](1);
        currentHeartbeats[0] = 1500;

        oracle.addChainlinkOracles(currentTokens, currentOracles, currentHeartbeats);

        vm.expectEmit(false, true, false, true);
        emit PricePosted(getNextUserAddress(), address(this), ape, 30 << 96, uint48(block.timestamp));
        oracle.setUnderlyingPriceX96(ape, 30 << 96, uint48(block.timestamp));
    }

    function testSetUnderlyingPriceX96WhenNotOwner() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = chainlinkOracles[0];
        uint48[] memory currentHeartbeats = new uint48[](1);
        currentHeartbeats[0] = 1500;

        oracle.addChainlinkOracles(currentTokens, currentOracles, currentHeartbeats);

        vm.prank(getNextUserAddress());
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setUnderlyingPriceX96(ape, 30 << 96, uint48(block.timestamp));
    }

    function testSetUnderlyingPriceX96WhenPriceIsTooOld() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = chainlinkOracles[0];
        uint48[] memory currentHeartbeats = new uint48[](1);
        currentHeartbeats[0] = 1500;

        oracle.addChainlinkOracles(currentTokens, currentOracles, currentHeartbeats);

        vm.expectRevert(ChainlinkOracle.PriceUpdateFailed.selector);
        oracle.setUnderlyingPriceX96(ape, 30 << 96, uint48(block.timestamp) - 86400);
    }
}
