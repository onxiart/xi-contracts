// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract OwnableBase {
    address _owner;

    event RenounceOwnership();

    constructor(address initialOwner) {
        _owner = initialOwner;
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        require(_owner == msg.sender, "only owner");
    }

    function owner() external view virtual returns (address) {
        return _owner;
    }

    function ownerRenounce() public onlyOwner {
        _owner = address(0);
        emit RenounceOwnership();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _owner = newOwner;
    }
}
