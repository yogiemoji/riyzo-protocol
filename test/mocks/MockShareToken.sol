// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockShareToken - ShareToken mock for testing
/// @dev Simplified mock that tracks mint/burn calls
contract MockShareToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Track operations for test verification
    address[] public mintedTo;
    uint256[] public mintedAmounts;
    address[] public burnedFrom;
    uint256[] public burnedAmounts;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        mintedTo.push(to);
        mintedAmounts.push(amount);
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        burnedFrom.push(from);
        burnedAmounts.push(amount);
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Test helpers
    function getMintCount() external view returns (uint256) {
        return mintedTo.length;
    }

    function getBurnCount() external view returns (uint256) {
        return burnedFrom.length;
    }

    function getLastMint() external view returns (address to, uint256 amount) {
        require(mintedTo.length > 0, "No mints");
        return (mintedTo[mintedTo.length - 1], mintedAmounts[mintedAmounts.length - 1]);
    }

    function getLastBurn() external view returns (address from, uint256 amount) {
        require(burnedFrom.length > 0, "No burns");
        return (burnedFrom[burnedFrom.length - 1], burnedAmounts[burnedAmounts.length - 1]);
    }
}
