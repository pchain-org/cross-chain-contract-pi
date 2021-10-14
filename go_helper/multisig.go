package eth

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	pbrige "github.com/pchain-org/cross-chain-contract-pi/go_abi/pbridge_abi"
	"github.com/pkg/errors"
)

func DeployPBridgeContract(chainID *big.Int, backend bind.ContractBackend, privkHex string, hexAddress []string) (common.Address, error) {
	var (
		err          error
		privk        *ecdsa.PrivateKey
		owners       []common.Address
		contractAddr common.Address
	)

	for i := 0; i < len(hexAddress); i++ {
		hexAddress[i] = strings.ToLower(hexAddress[i])
	}
	sort.Slice(hexAddress, func(i, j int) bool {
		return hexAddress[i] < hexAddress[j]
	})

	// init vars
	privk, err = crypto.HexToECDSA(privkHex)
	if err != nil {
		return contractAddr, fmt.Errorf("convert privkey error,%v", err)
	}
	for _, ha := range hexAddress {
		owners = append(owners, common.HexToAddress(ha))
	}

	auth, err := bind.NewKeyedTransactorWithChainID(privk, chainID)
	if err != nil {
		return contractAddr, fmt.Errorf("TransactOpts error,%v", err)
	}
	contractAddr, tx, _, err := pbrige.DeployPBridge(auth, backend, owners)
	if err != nil {
		return contractAddr, fmt.Errorf("deploy PBridge error, %v", err)
	}
	_ = tx
	return contractAddr, nil
}

// MultiSignTx return sig byte
func MultiSignTx(txKey, signerPrivkHex string, isERC20 bool, erc20ContractAddr, destinationAddr common.Address, value *big.Int, version int64) ([]byte, error) {
	addressTy, _ := abi.NewType("address", "", nil)
	stringTy, _ := abi.NewType("string", "", nil)
	uintTy, _ := abi.NewType("uint256", "", nil)
	boolTy, _ := abi.NewType("bool", "", nil)
	arguments := abi.Arguments{
		{
			Type: stringTy,
		}, {
			Type: addressTy,
		}, {
			Type: uintTy,
		}, {
			Type: boolTy,
		}, {
			Type: addressTy,
		}, {
			Type: uintTy,
		},
	}
	bytes, err := arguments.Pack(
		txKey,
		destinationAddr,
		value,
		isERC20,
		erc20ContractAddr,
		big.NewInt(version),
	)
	if err != nil {
		fmt.Println(err)
	}
	hashBytes := crypto.Keccak256(
		bytes,
	)

	privk, err := crypto.HexToECDSA(signerPrivkHex)
	if err != nil {
		return nil, err
	}
	sig, err := crypto.Sign(hashBytes, privk)
	if err != nil {
		return nil, errors.Wrap(err, "crypto sign failed")
	}
	return sig, nil
}

type TxDynamicParams struct {
	Backend                              bind.ContractBackend
	TxKey                                string
	Signs                                []byte
	PrivkHex                             string
	MultisigContractAddress, FromAddress common.Address
	IsERC20                              bool
	ERC20Addr, ERC721Addr                common.Address
	Destination                          common.Address //toAddress
	Value, TokenId                       *big.Int
	TokenURI                             string
	ChainID                              *big.Int
}

// ExecuteTX
func ExecuteDynamicTX(txp *TxDynamicParams) (string, error) {
	// init vars
	privk, err := crypto.HexToECDSA(txp.PrivkHex)
	if err != nil {
		return "", err
	}
	multisigContract, err := pbrige.NewPBridge(txp.MultisigContractAddress, txp.Backend)
	if err != nil {
		return "", fmt.Errorf("deloy error, please check contract address and rpc server,%v", err)
	}

	{
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*5)
		defer cancel()
		nonce, err := txp.Backend.PendingNonceAt(ctx, txp.FromAddress)
		if err != nil {
			return "", fmt.Errorf("get nonce error, %v", err)
		}
		dst := make([]byte, hex.EncodedLen(len(txp.Signs)))
		hex.Encode(dst, txp.Signs)
		signer := types.LatestSignerForChainID(txp.ChainID)
		// fmt.Printf("txp.TxKey: %s,txp.Destination: %s, txp.Value: %v, txp.MultisigContractAddress: %s\n",
		// txp.TxKey, txp.Destination, txp.Value, txp.MultisigContractAddress)
		// fmt.Printf("txp.Sig: %s\n", dst)
		tx, err := multisigContract.CreateOrSignWithdraw(&bind.TransactOpts{
			From:  txp.FromAddress,
			Nonce: big.NewInt(int64(nonce)),
			Signer: func(address common.Address, tx *types.Transaction) (*types.Transaction, error) {
				signature, err := crypto.Sign(signer.Hash(tx).Bytes(), privk)
				if err != nil {
					return nil, err
				}
				return tx.WithSignature(signer, signature)
			},
			Context: ctx,
		}, //txKey string, to common.Address, amount *big.Int, isERC20 bool, ERC20 common.Address, signatures []byte)
			txp.TxKey,
			txp.Destination,
			txp.Value,
			txp.IsERC20,
			txp.ERC20Addr,
			txp.Signs)
		if err != nil {
			return "", fmt.Errorf("call contract error, %v", err)
		}
		return tx.Hash().Hex(), nil
	}

}

// DynamicMultiSignNFTTx return sig byte
func DynamicMultiSignNFTTx(txKey, signerPrivkHex, tokenURI string, erc721ContractAddr, destinationAddr common.Address, tokenId *big.Int, version int64) ([]byte, error) {
	addressTy, _ := abi.NewType("address", "", nil)
	stringTy, _ := abi.NewType("string", "", nil)
	uintTy, _ := abi.NewType("uint256", "", nil)
	arguments := abi.Arguments{
		{
			Type: stringTy,
		}, {
			Type: addressTy,
		}, {
			Type: addressTy,
		}, {
			Type: uintTy,
		}, {
			Type: stringTy,
		}, {
			Type: uintTy,
		},
	}
	bytes, err := arguments.Pack(
		txKey,
		erc721ContractAddr,
		destinationAddr,
		tokenId,
		tokenURI,
		big.NewInt(version),
	)
	if err != nil {
		fmt.Println(err)
	}
	hashBytes := crypto.Keccak256(
		bytes,
	)

	privk, err := crypto.HexToECDSA(signerPrivkHex)
	if err != nil {
		return nil, err
	}
	sig, err := crypto.Sign(hashBytes, privk)
	if err != nil {
		return nil, errors.Wrap(err, "crypto sign failed")
	}
	return sig, nil
}

// ExecuteDynamicNFT .
func ExecuteDynamicNFT(txp *TxDynamicParams) (string, error) {
	// init vars
	privk, err := crypto.HexToECDSA(txp.PrivkHex)
	if err != nil {
		return "", err
	}
	multisigContract, err := pbrige.NewPBridge(txp.MultisigContractAddress, txp.Backend)
	if err != nil {
		return "", fmt.Errorf("deloy error, please check contract address and rpc server,%v", err)
	}

	{
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*5)
		defer cancel()
		nonce, err := txp.Backend.PendingNonceAt(ctx, txp.FromAddress)
		if err != nil {
			return "", fmt.Errorf("get nonce error, %v", err)
		}
		dst := make([]byte, hex.EncodedLen(len(txp.Signs)))
		hex.Encode(dst, txp.Signs)
		signer := types.LatestSignerForChainID(txp.ChainID)
		tx, err := multisigContract.CreateOrSignWithdrawERC721(&bind.TransactOpts{
			From:  txp.FromAddress,
			Nonce: big.NewInt(int64(nonce)),
			Signer: func(address common.Address, tx *types.Transaction) (*types.Transaction, error) {
				signature, err := crypto.Sign(signer.Hash(tx).Bytes(), privk)
				if err != nil {
					return nil, err
				}
				return tx.WithSignature(signer, signature)
			},
			Context: ctx,
		},
			txp.TxKey,
			txp.ERC721Addr,
			txp.Destination,
			txp.TokenId,
			txp.TokenURI,
			txp.Signs)
		if err != nil {
			return "", fmt.Errorf("call contract error, %v", err)
		}
		return tx.Hash().Hex(), nil
	}
}
