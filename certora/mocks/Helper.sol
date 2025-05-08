
pragma solidity >=0.8.4 <0.9.0;

contract Helper  {

    function getBytesHash(bytes calldata b ) external view returns (bytes32) {
        return keccak256(b);
    }
}