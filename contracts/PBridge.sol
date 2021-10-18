// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interface/IERC20Minter.sol";
import "./interface/IERC721Minter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

contract PBridge is ERC721Holder {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using BytesLib for bytes;

    modifier isOwner() {
        require(owner == msg.sender, "Only owner can execute it");
        _;
    }
    modifier isManager() {
        require(managers[msg.sender] == 1, "Only manager can execute it");
        _;
    }
    bool public upgrade = false;
    address public upgradeContractAddress = address(0);
    // max managers
    uint256 public max_managers = 15;
    // min managers
    uint256 public min_managers = 3;
    // multi sign rate 66%
    uint256 public rate = 66;
    // signature Length
    uint256 public signatureLength = 65;
    // multi sign DENOMINATOR
    uint256 constant DENOMINATOR = 100;
    // contract version
    uint256 constant VERSION = 1;
    // multi sign min signatures
    uint8 public current_min_signatures;
    address public owner;
    mapping(address => uint8) private seedManagers;
    address[] private seedManagerArray;
    mapping(address => uint8) private managers;
    address[] private managerArray;
    mapping(bytes32 => uint8) private completedKeccak256s;
    mapping(string => uint8) private completedTxs;
    mapping(address => uint8) private minterERC20s;
    mapping(address => uint8) private minterERC721s;
    
    constructor(address[] memory _managers) public {
        require(
            _managers.length <= max_managers,
            "Exceeded the maximum number of managers"
        );
        require(
            _managers.length >= min_managers,
            "Not reaching the min number of managers"
        );
        owner = msg.sender;
        managerArray = _managers;
        for (uint8 i = 0; i < managerArray.length; i++) {
            managers[managerArray[i]] = 1;
            seedManagers[managerArray[i]] = 1;
            seedManagerArray.push(managerArray[i]);
        }
        require(managers[owner] == 0, "Contract creator cannot act as manager");
        // set multi sign min signatures
        current_min_signatures = calMinSignatures(managerArray.length);
    }

    fallback() external payable {}

    receive() external payable {
        emit DepositFunds(msg.sender, msg.value);
    }

    function executeWithdrawTx(
        string memory txKey,
        address payable to,
        uint256 amount,
        bool isERC20,
        address ERC20,
        bytes memory signatures
    ) public isManager {
        require(bytes(txKey).length == 64, "Fixed length of txKey: 64");
        require(to != address(0), "Withdraw: transfer to the zero address");
        require(amount > 0, "Withdrawal amount must be greater than 0");
        // Verify completed tx
        require(completedTxs[txKey] == 0, "Transaction has been completed");
        // Verify transfer
        if (isERC20) {
            validateTransferERC20(ERC20, to, amount);
        } else {
            require(
                address(this).balance >= amount,
                "This contract address does not have sufficient balance of ether"
            );
        }
        bytes32 vHash = keccak256(
            abi.encode(txKey, to, amount, isERC20, ERC20, VERSION)
        );
        // Verify request repeatability
        require(completedKeccak256s[vHash] == 0, "Invalid signatures");
        // Verify signature
        require(validSignature(vHash, signatures), "Valid signatures fail");
        // Execute transfer
        if (isERC20) {
            transferERC20(ERC20, to, amount);
        } else {
            // Actual arrival
            require(
                address(this).balance >= amount,
                "This contract address does not have sufficient balance of ether"
            );
            to.transfer(amount);
            emit TransferFunds(to, amount);
        }
        // Save transaction 
        completeTx(txKey, vHash, 1);
        emit TxWithdrawCompleted(txKey);
    }

    function executeWithdrawTxERC721(
        string memory txKey,
        address ERC721,
        address to,
        uint256 tokenId,
        string calldata tokenURI,
        bytes memory signatures
    ) public isManager {
        require(bytes(txKey).length == 64, "Fixed length of txKey: 64");
        require(to != address(0), "Withdraw: transfer to the zero address");
        // Verify completed transactions
        require(completedTxs[txKey] == 0, "Transaction has been completed");
        // Verify transfer
        validateTransferERC721(ERC721, to, tokenId);
        bytes32 vHash = keccak256(
            abi.encode(txKey, ERC721, to, tokenId, tokenURI, VERSION)
        );
        // Verify request repeatability
        require(completedKeccak256s[vHash] == 0, "Invalid signatures");
        // Verify signature
        require(validSignature(vHash, signatures), "Valid signatures fail");
        // Actual arrival
        transferERC721(ERC721, to, tokenId, tokenURI);
        // Save transaction 
        completeTx(txKey, vHash, 1);
        emit TxWithdrawCompleted(txKey);
    }

    function executeManagerChange(
        string memory txKey,
        address[] memory adds,
        address[] memory removes,
        uint8 count,
        bytes memory signatures
    ) public isManager {
        require(bytes(txKey).length == 64, "Fixed length of txKey: 64");
        require(
            adds.length > 0 || removes.length > 0,
            "There are no managers joining or exiting"
        );
        // Verify completed transactions
        require(completedTxs[txKey] == 0, "Transaction has been completed");
        preValidateAddsAndRemoves(adds, removes);
        bytes32 vHash = keccak256(
            abi.encode(txKey, adds, count, removes, VERSION)
        );
        // Verify request repeatability
        require(completedKeccak256s[vHash] == 0, "Invalid signatures");
        // Verify signature
        require(validSignature(vHash, signatures), "Valid signatures fail");
        // Change Manager
        removeManager(removes);
        addManager(adds);
        // Update the minimum number of signatures
        current_min_signatures = calMinSignatures(managerArray.length);
        // Save transaction
        completeTx(txKey, vHash, 1);
        // add event
        emit TxManagerChangeCompleted(txKey);
    }

    function executeUpgrade(
        string memory txKey,
        address upgradeContract,
        bytes memory signatures
    ) public isManager {
        require(bytes(txKey).length == 64, "Fixed length of txKey: 64");
        // Verify completed transactions
        require(completedTxs[txKey] == 0, "Transaction has been completed");
        require(!upgrade, "It has been upgraded");
        require(
            upgradeContract.isContract(),
            "The address is not a contract address"
        );
        // Verify
        bytes32 vHash = keccak256(abi.encode(txKey, upgradeContract, VERSION));
        // Verify request repeatability
        require(completedKeccak256s[vHash] == 0, "Invalid signatures");
        // Verify signature
        require(validSignature(vHash, signatures), "Valid signatures fail");
        // Enable upgraded
        upgrade = true;
        upgradeContractAddress = upgradeContract;
        // Save transaction
        completeTx(txKey, vHash, 1);
        // add event
        emit TxUpgradeCompleted(txKey);
    }

    function validSignature(bytes32 hash, bytes memory signatures)
        internal
        view
        returns (bool)
    {
        require(signatures.length <= 975, "Max length of signatures: 975");
        // Verify signature
        uint256 sManagersCount = getManagerFromSignatures(hash, signatures);
        // Verify the minimum number of signatures
        return sManagersCount >= current_min_signatures;
    }

    function getManagerFromSignatures(bytes32 hash, bytes memory signatures)
        internal
        view
        returns (uint256)
    {
        uint256 signCount = 0;
        uint256 times = signatures.length.div(signatureLength);
        address[] memory result = new address[](times);
        uint256 k = 0;
        uint8 j = 0;
        for (uint256 i = 0; i < times; i++) {
            bytes memory sign = signatures.slice(k, signatureLength);
            address mAddress = ecrecovery(hash, sign);
            require(mAddress != address(0), "Signatures error");
            // Manager count
            if (managers[mAddress] == 1) {
                signCount++;
                result[j++] = mAddress;
            }
            k += signatureLength;
        }
        // Verify address repeatability
        bool suc = repeatability(result);
        delete result;
        require(suc, "Signatures duplicate");
        return signCount;
    }

    function validateRepeatability(
        address currentAddress,
        address[] memory list
    ) internal pure returns (bool) {
        address tempAddress;
        for (uint256 i = 0; i < list.length; i++) {
            tempAddress = list[i];
            if (tempAddress == address(0)) {
                break;
            }
            if (tempAddress == currentAddress) {
                return false;
            }
        }
        return true;
    }

    function repeatability(address[] memory list) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            address address1 = list[i];
            if (address1 == address(0)) {
                break;
            }
            for (uint256 j = i + 1; j < list.length; j++) {
                address address2 = list[j];
                if (address2 == address(0)) {
                    break;
                }
                if (address1 == address2) {
                    return false;
                }
            }
        }
        return true;
    }

    function ecrecovery(bytes32 hash, bytes memory sig)
        internal
        view
        returns (address)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;
        if (sig.length != signatureLength) {
            return address(0);
        }
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            return address(0);
        }
        // https://github.com/ethereum/go-ethereum/issues/2053
        if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            return address(0);
        }
        return ecrecover(hash, v, r, s);
    }

    function preValidateAddsAndRemoves(
        address[] memory adds,
        address[] memory removes
    ) internal view {
        // Verify address
        uint256 addLen = adds.length;
        for (uint256 i = 0; i < addLen; i++) {
            address add = adds[i];
            require(add != address(0), "ERROR: Detected zero address in adds");
            require(
                managers[add] == 0,
                "The address list that is being added already exists as a manager"
            );
        }
        require(
            repeatability(adds),
            "Duplicate parameters for the address to join"
        );
        // Verify owner
        require(
            validateRepeatability(owner, adds),
            "Contract creator cannot act as manager"
        );
        // Verify removes
        require(
            repeatability(removes),
            "Duplicate parameters for the address to exit"
        );
        uint256 removeLen = removes.length;
        for (uint256 i = 0; i < removeLen; i++) {
            address remove = removes[i];
            require(seedManagers[remove] == 0, "Can't exit seed manager");
            require(
                managers[remove] == 1,
                "There are addresses in the exiting address list that are not manager"
            );
        }
        require(
            managerArray.length + adds.length - removes.length <= max_managers,
            "Exceeded the maximum number of managers"
        );
    }

    /*
      The minimum number of signatures is calculated according to the current number of valid administrators and the minimum signature ratio, rounded up
    */
    function calMinSignatures(uint256 managerCounts)
        internal
        view
        returns (uint8)
    {
        require(managerCounts > 0, "Manager Can't empty.");
        uint256 numerator = rate * managerCounts + DENOMINATOR - 1;
        return uint8(numerator / DENOMINATOR);
    }

    function removeManager(address[] memory removes) internal {
        if (removes.length == 0) {
            return;
        }
        for (uint256 i = 0; i < removes.length; i++) {
            delete managers[removes[i]];
        }
        for (uint256 i = 0; i < managerArray.length; i++) {
            if (managers[managerArray[i]] == 0) {
                delete managerArray[i];
            }
        }
        uint256 tempIndex = 0x10;
        for (uint256 i = 0; i < managerArray.length; i++) {
            address temp = managerArray[i];
            if (temp == address(0)) {
                if (tempIndex == 0x10) tempIndex = i;
                continue;
            } else if (tempIndex != 0x10) {
                managerArray[tempIndex] = temp;
                tempIndex++;
            }
        }
    }

    function addManager(address[] memory adds) internal {
        if (adds.length == 0) {
            return;
        }
        for (uint256 i = 0; i < adds.length; i++) {
            address add = adds[i];
            if (managers[add] == 0) {
                managers[add] = 1;
                managerArray.push(add);
            }
        }
    }

    function completeTx(
        string memory txKey,
        bytes32 keccak256Hash,
        uint8 e
    ) internal {
        completedTxs[txKey] = e;
        completedKeccak256s[keccak256Hash] = e;
    }

    function validateTransferERC20(
        address ERC20,
        address to,
        uint256 amount
    ) internal view {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(address(this) != ERC20, "Do nothing by yourself");
        require(ERC20.isContract(), "The address is not a contract address");
        if (isMinterERC20(ERC20)) {
            return;
        }
        IERC20 token = IERC20(ERC20);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "No enough balance of token");
    }

    function transferERC20(
        address ERC20,
        address to,
        uint256 amount
    ) internal {
        if (isMinterERC20(ERC20)) {
            IERC20Minter minterToken = IERC20Minter(ERC20);
            minterToken.mint(to, amount);
            return;
        }
        IERC20 token = IERC20(ERC20);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "No enough balance of token");
        token.safeTransfer(to, amount);
    }

    function validateTransferERC721(
        address ERC721,
        address to,
        uint256 tokenId
    ) internal view {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(address(this) != ERC721, "Do nothing by yourself");
        require(ERC721.isContract(), "The address is not a contract address");
        if (isMinterERC721(ERC721)) {
            return;
        }
        IERC721 token = IERC721(ERC721);
        address tokenOwner = token.ownerOf(tokenId);
        require(tokenOwner == address(this), "Not owner of token");
    }

    function transferERC721(
        address ERC721,
        address to,
        uint256 tokenId,
        string memory tokenURI
    ) internal {
        if (isMinterERC721(ERC721)) {
            IERC721Minter minterToken = IERC721Minter(ERC721);
            minterToken.mint(to, tokenURI);
            return;
        }
        address from = address(this);
        IERC721 token = IERC721(ERC721);
        token.safeTransferFrom(from, to, tokenId);
    }

    function closeUpgrade() public isOwner {
        require(upgrade, "Denied");
        upgrade = false;
    }

    function upgradeContractS1() public isOwner {
        require(upgrade, "Denied");
        require(
            upgradeContractAddress != address(0),
            "ERROR: transfer to the zero address"
        );
        payable(address(uint160(upgradeContractAddress))).transfer(
            address(this).balance
        );
    }

    function upgradeContractS2(address ERC20) public isOwner {
        require(upgrade, "Denied");
        require(
            upgradeContractAddress != address(0),
            "ERROR: transfer to the zero address"
        );
        require(address(this) != ERC20, "Do nothing by yourself");
        require(ERC20.isContract(), "The address is not a contract address");
        IERC20 token = IERC20(ERC20);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= 0, "No enough balance of token");
        token.safeTransfer(upgradeContractAddress, balance);
        if (isMinterERC20(ERC20)) {
            // 定制的ERC20，转移增发销毁权限到新多签合约
            IERC20Minter minterToken = IERC20Minter(ERC20);
            minterToken.replaceMinter(upgradeContractAddress);
        }
    }

    // Is Customized ERC20
    function isMinterERC20(address ERC20) public view returns (bool) {
        return minterERC20s[ERC20] > 0;
    }

    // Register Customized ERC20
    function registerMinterERC20(address ERC20) public isOwner {
        require(address(this) != ERC20, "Do nothing by yourself");
        require(ERC20.isContract(), "The address is not a contract address");
        require(
            !isMinterERC20(ERC20),
            "This address has already been registered"
        );
        minterERC20s[ERC20] = 1;
    }

    // Unregister Customized ERC20 
    function unregisterMinterERC20(address ERC20) public isOwner {
        require(isMinterERC20(ERC20), "This address is not registered");
        delete minterERC20s[ERC20];
    }

    // Is Customized ERC721
    function isMinterERC721(address ERC721) public view returns (bool) {
        return minterERC721s[ERC721] > 0;
    }

    // Register Customized ERC721
    function registerMinterERC721(address ERC721) public isOwner {
        require(address(this) != ERC721, "Do nothing by yourself");
        require(ERC721.isContract(), "The address is not a contract address");
        require(
            !isMinterERC721(ERC721),
            "This address has already been registered"
        );
        minterERC721s[ERC721] = 1;
    }

    // Unregister Customized ERC721
    function unregisterMinterERC721(address ERC721) public isOwner {
        require(isMinterERC721(ERC721), "This address is not registered");
        delete minterERC721s[ERC721];
    }

    function crossOut(
        string memory to,
        uint256 amount,
        address ERC20
    ) public payable returns (bool) {
        address from = msg.sender;
        require(amount > 0, "ERROR: Zero amount");
        if (ERC20 != address(0)) {
            require(msg.value == 0, "ERC20: Does not accept Ethereum Coin");
            require(
                ERC20.isContract(),
                "The address is not a contract address"
            );
            IERC20 token = IERC20(ERC20);
            uint256 allowance = token.allowance(from, address(this));
            require(allowance >= amount, "No enough amount for authorization");
            uint256 fromBalance = token.balanceOf(from);
            require(fromBalance >= amount, "No enough balance of the token");
            token.safeTransferFrom(from, address(this), amount);
            if (isMinterERC20(ERC20)) {
                IERC20Minter minterToken = IERC20Minter(ERC20);
                minterToken.burn(amount);
            }
        } else {
            require(msg.value == amount, "Inconsistency Ethereum amount");
        }
        emit CrossOutFunds(from, to, amount, ERC20);
        return true;
    }

    function crossOutERC721(
        string memory to,
        address ERC721,
        uint256 tokenId
    ) public returns (bool) {
        address from = msg.sender;
        require(ERC721.isContract(), "The address is not a contract address");
        require(tokenId > 0, "ERROR: Zero amount");
        IERC721 token = IERC721(ERC721);
        token.safeTransferFrom(from, address(this), tokenId);
        if (isMinterERC721(ERC721)) {
            IERC721Minter minterToken = IERC721Minter(ERC721);
            minterToken.burn(tokenId);
        }
        emit CrossOutERC721(from, to, tokenId, ERC721);
        return true;
    }

    function isCompletedTx(string memory txKey) public view returns (bool) {
        return completedTxs[txKey] > 0;
    }

    function ifManager(address _manager) public view returns (bool) {
        return managers[_manager] == 1;
    }

    function allManagers() public view returns (address[] memory) {
        return managerArray;
    }

    event DepositFunds(address from, uint256 amount);
    event CrossOutFunds(address from, string to, uint256 amount, address ERC20);
    event CrossOutERC721(
        address from,
        string to,
        uint256 tokenId,
        address ERC721
    );
    event TransferFunds(address to, uint256 amount);
    event TxWithdrawCompleted(string txKey);
    event TxManagerChangeCompleted(string txKey);
    event TxUpgradeCompleted(string txKey);
}