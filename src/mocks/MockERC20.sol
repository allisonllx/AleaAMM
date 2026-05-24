// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    // Pass the name and symbol up to the OpenZeppelin template constructor
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /**
     * @notice Generates play tokens out of thin air for local sandbox testing.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
