// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@zkbob/interfaces/IBurnableERC20.sol";
import "@zkbob/interfaces/IMintableERC20.sol";
import "@zkbob/interfaces/IERC20Permit.sol";
import "@zkbob/interfaces/IERC677.sol";
import "@LayerZero/token/oft/v2/interfaces/IOFTV2.sol";

interface IEclypseUSD is IOFTV2, IERC20Permit, IMintableERC20, IBurnableERC20, IERC20, IERC677 {}
