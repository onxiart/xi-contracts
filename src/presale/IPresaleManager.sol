// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPresaleManager {
    error AlreadyFinalized();
    error ZeroQuantity();
    error PurchaseTooLarge(uint256 provided, uint256 maxAllowed);
    error SoldOut(uint256 attempted, uint256 remaining);
    error IncorrectPayment(uint256 provided, uint256 expected);
    error NotSoldOut(uint256 sold, uint256 cap);
    error TransferFailed();
    error DirectTransferNotAllowed();
    error ZeroAddress();
    error ZeroValue();
    error CannotRescueXi();
    error PoolFrontrunDetected();

    event Purchased(
        address indexed user,
        uint256 quantity,
        uint256 xiAmount,
        uint256 bnbPaid,
        uint256 totalSold,
        uint256 totalRaised
    );
    event Finalized(uint256 lpTokenId, uint256 sqrtPriceX96, uint128 liquidity);
    event Erc20Rescued(address indexed token, address indexed to, uint256 amount);

    function HARD_CAP() external view returns (uint256);
    function TEAM_BNB() external view returns (uint256);
    function LP_BNB() external view returns (uint256);
    function PRICE_PER_XI() external view returns (uint256);
    function TEAM_TOKENS() external view returns (uint256);
    function LP_TOKENS() external view returns (uint256);
    function PRESALE_TOKENS() external view returns (uint256);

    function team() external view returns (address);
    function admin() external view returns (address);
    function sold() external view returns (uint256);
    function raised() external view returns (uint256);
    function lpReserve() external view returns (uint256);
    function finalized() external view returns (bool);
    function lpTokenId() external view returns (uint256);
    function purchased(address user) external view returns (uint256);
    function remaining() external view returns (uint256);

    function buy(uint256 quantity) external payable;
    function finalize() external;

    /// @notice Recover non-XI ERC20 tokens mistakenly sent to this contract.
    /// XI itself is forbidden (protects buyers' allocation). Owner-only.
    function rescueERC20(address token, address to, uint256 amount) external;
}
