// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.29; 

interface IAccount { 

    function validateUserOp( 

        UserOperation calldata userOp, 

        bytes32 userOpHash, 

        uint256 missingFunds 

    ) external returns (uint256 validationData); 

} 

interface IPaymaster { 

    function validatePaymasterUserOp( 

        UserOperation calldata userOp, 

        bytes32 userOpHash, 

        uint256 maxCost 

    ) external returns (bytes memory context, uint256 validationData); 

    function postOp( 

        PostOpMode mode, 

        bytes calldata context, 

        uint256 actualGasCost 

    ) external; 

} 

struct UserOperation { 

    address sender; 

    uint256 nonce; 

    bytes initCode; 

    bytes callData; 

    uint256 callGasLimit; 

    uint256 verificationGasLimit; 

    uint256 preVerificationGas; 

    uint256 maxFeePerGas; 

    uint256 maxPriorityFeePerGas; 

    bytes paymasterAndData; 

    bytes signature; 

} 

enum PostOpMode { 

    opSucceeded, 

    opReverted, 

    postOpReverted 

} 

contract EntryPoint4337 { 

    event UserOperationEvent( 

        bytes32 indexed userOpHash, 

        address indexed sender, 

        address indexed paymaster, 

        uint256 nonce, 

        bool success, 

        uint256 actualGasCost, 

        uint256 actualGasUsed 

    ); 

    event Deposited(address indexed account, uint256 amount); 

    event Withdrawn(address indexed account, address withdrawAddress, uint256 amount); 

    mapping(address => uint256) public deposits; 

    mapping(address => uint256) public nonceSequence; 

    function getUserOpHash(UserOperation calldata userOp) public view returns (bytes32) { 

        return keccak256( 

            abi.encode( 

                keccak256( 

                    abi.encode( 

                        userOp.sender, 

                        userOp.nonce, 

                        keccak256(userOp.initCode), 

                        keccak256(userOp.callData), 

                        userOp.callGasLimit, 

                        userOp.verificationGasLimit, 

                        userOp.preVerificationGas, 

                        userOp.maxFeePerGas, 

                        userOp.maxPriorityFeePerGas, 

                        keccak256(userOp.paymasterAndData) 

                    ) 

                ), 

                address(this), 

                block.chainid 

            ) 

        ); 

    } 

    function depositTo(address account) external payable { 

        deposits[account] += msg.value; 

        emit Deposited(account, msg.value); 

    } 

    function withdrawTo(address payable withdrawAddress, uint256 amount) external { 

        uint256 balance = deposits[msg.sender]; 

        require(balance >= amount, "INSUFFICIENT_DEPOSIT"); 

        deposits[msg.sender] = balance - amount; 

        withdrawAddress.transfer(amount); 

        emit Withdrawn(msg.sender, withdrawAddress, amount); 

    } 

    function handleOps( 

        UserOperation[] calldata ops, 

        address payable beneficiary 

    ) external { 

        uint256 length = ops.length; 

        for (uint256 i = 0; i < length; i++) { 

            _handleOp(ops[i], beneficiary); 

        } 

    } 

    function _handleOp( 

        UserOperation calldata userOp, 

        address payable beneficiary 

    ) internal { 

        uint256 preGas = gasleft(); 

        bytes32 userOpHash = getUserOpHash(userOp); 

        _validateUserOp(userOp, userOpHash); 

        bool success; 

        bytes memory result; 

        (success, result) = userOp.sender.call{ 

            gas: userOp.callGasLimit 

        }(userOp.callData); 

        uint256 gasUsed = preGas - gasleft(); 

        uint256 gasCost = gasUsed * _gasPrice(userOp); 

        _chargeGas(userOp, gasCost, beneficiary); 

        emit UserOperationEvent( 

            userOpHash, 

            userOp.sender, 

            _getPaymaster(userOp), 

            userOp.nonce, 

            success, 

            gasCost, 

            gasUsed 

        ); 

    } 

    function _validateUserOp( 

        UserOperation calldata userOp, 

        bytes32 userOpHash 

    ) internal { 

        require(userOp.nonce == nonceSequence[userOp.sender]++, "INVALID_NONCE"); 

        uint256 requiredPrefund = 

            (userOp.callGasLimit + 

                userOp.verificationGasLimit + 

                userOp.preVerificationGas) * 

            userOp.maxFeePerGas; 

        address paymaster = _getPaymaster(userOp); 

        if (paymaster == address(0)) { 

            uint256 balance = deposits[userOp.sender]; 

            require(balance >= requiredPrefund, "INSUFFICIENT_FUNDS"); 

            deposits[userOp.sender] = balance - requiredPrefund; 

        } 

        uint256 validationData = 

            IAccount(userOp.sender).validateUserOp( 

                userOp, 

                userOpHash, 

                paymaster == address(0) ? requiredPrefund : 0 

            ); 

        require(validationData == 0, "ACCOUNT_VALIDATION_FAILED"); 

        if (paymaster != address(0)) { 

            IPaymaster(paymaster).validatePaymasterUserOp( 

                userOp, 

                userOpHash, 

                requiredPrefund 

            ); 

        } 

    } 

    function _chargeGas( 

        UserOperation calldata userOp, 

        uint256 gasCost, 

        address payable beneficiary 

    ) internal { 

        address paymaster = _getPaymaster(userOp); 

        if (paymaster == address(0)) { 

            beneficiary.transfer(gasCost); 

        } else { 

            IPaymaster(paymaster).postOp( 

                PostOpMode.opSucceeded, 

                userOp.paymasterAndData, 

                gasCost 

            ); 

        } 

    } 

    function _gasPrice(UserOperation calldata userOp) internal view returns (uint256) { 

        return min( 

            userOp.maxFeePerGas, 

            userOp.maxPriorityFeePerGas + block.basefee 

        ); 

    } 

    function _getPaymaster(UserOperation calldata userOp) internal pure returns (address) { 

        if (userOp.paymasterAndData.length < 20) return address(0); 

        return address(bytes20(userOp.paymasterAndData[0:20])); 

    } 

    function min(uint256 a, uint256 b) internal pure returns (uint256) { 

        return a < b ? a : b; 

    } 

    receive() external payable {} 

} 