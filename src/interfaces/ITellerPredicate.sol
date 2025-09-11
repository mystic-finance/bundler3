import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

struct PredicateMessage {
    // the unique identifier for the task
    string taskId;
    // the expiration block number for the task
    uint256 expireByBlockNumber;
    // the operators that have signed the task
    address[] signerAddresses;
    // the signatures of the operators that have signed the task
    bytes[] signatures;
}

struct BridgeData {
    uint32 chainSelector;
    address destinationChainReceiver;
    IERC20 bridgeFeeToken;
    uint64 messageGas;
    bytes data;
}

interface ICrossChainTellerBase {
    function depositAndBridge(
        IERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        BridgeData calldata data
    ) external;

    function previewFee(uint256 shareAmount, BridgeData calldata data) external view returns (uint256 fee);
    function bridge(
        uint256 shareAmount,
        BridgeData calldata data
    ) external returns (bytes32 messageId);
}


interface ITellerPredicate {
    function deposit(
        IERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address recipient,
        ICrossChainTellerBase teller,
        PredicateMessage calldata predicateMessage
    ) external;

    function depositAndBridge(
        IERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        BridgeData calldata data,
        ICrossChainTellerBase teller,
        PredicateMessage calldata predicateMessage
    )
    external;

    function genericUserCheckPredicate(
        address user,
        PredicateMessage calldata predicateMessage
    )
    external view returns (bool);
}