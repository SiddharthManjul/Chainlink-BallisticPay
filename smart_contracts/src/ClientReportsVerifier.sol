// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Common} from "@chainlink/contracts/src/v0.8/llo-feeds/libraries/Common.sol";
import {IVerifierFeeManager} from "@chainlink/contracts/src/v0.8/llo-feeds/v0.3.0/interfaces/IVerifierFeeManager.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

interface IVerifierProxy {
    function verify(
        bytes calldata payload,
        bytes calldata parameterPayload
    ) external payable returns (bytes memory verifierResponse);

    function verifyBulk(
        bytes[] calldata payloads,
        bytes calldata parameterPayload
    ) external payable returns (bytes[] memory verifierReports);

    function s_feeManager() external view returns (IVerifierFeeManager);
}

interface IFeeManager {
    function getFeeAndReward(
        address subscriber,
        bytes memory unverifiedReport,
        address quoteAddress
    ) external returns (Common.Asset memory, Common.Asset memory, uint256);

    function i_linkAddress() external view returns (address);
    function i_nativeAddress() external view returns (address);
    function i_rewardManager() external view returns (address);
}

contract ClientReportsVerifier {
    
    error NothingToWithdraw();
    error NotOwner(address caller);
    error InvalidReportVersion(uint16 version);

    struct ReportV3 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }

    struct ReportV4 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        uint32 marketStatus;
    }

    IVerifierProxy public immutable i_verifierProxy;
    address private immutable i_owner;
    int192 public lastDecodedPrice;
    event DecodedPrice(int192 price);

    constructor(address _verifierProxy) {
        i_owner = msg.sender;
        i_verifierProxy = IVerifierProxy(_verifierProxy);
    }

    modifier onlyOwner() {
        if (msg.sender != i_owner) revert NotOwner(msg.sender);
        _;
    }

    function verifyReport(bytes memory unverifiedReport) external {
        (, bytes memory reportData) = abi.decode(
            unverifiedReport,
            (bytes32[3], bytes)
        );

        uint16 reportVersion = (uint16(uint8(reportData[0])) << 8) |
            uint16(uint8(reportData[1]));
        if (reportVersion != 3 && reportVersion != 4)
            revert InvalidReportVersion(reportVersion);
        
        IFeeManager feeManager = IFeeManager(
            address(i_verifierProxy.s_feeManager())
        );

        bytes memory parameterPayload;
        if(address(feeManager) != address(0)) {
            address feeToken = feeManager.i_linkAddress();

            (Common.Asset memory fee, , ) = feeManager.getFeeAndReward(
                address(this),
                reportData,
                feeToken
            );

            IERC20(feeToken).approve(feeManager.i_rewardManager(), fee.amount);
            parameterPayload = abi.encode(feeToken);

        } else {
            parameterPayload = bytes("");
        }

        bytes memory verified = i_verifierProxy.verify(
            unverifiedReport,
            parameterPayload
        );

        if (reportVersion == 3) {
            int192 price = abi.decode(verified, (ReportV3)).price;
            lastDecodedPrice = price;
            emit DecodedPrice(price);
        } else {
            int192 price = abi.decode(verified, (ReportV4)).price;
            lastDecodedPrice = price;
            emit DecodedPrice(price);
        }
    }

    function withdrawToken(
        address _beneficiary,
        address _token
    ) external onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_beneficiary, amount);
    }
}
