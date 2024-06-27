pragma solidity 0.8.25;

import {IDelegator} from "./IDelegator.sol";

interface IFullRestakeDelegator is IDelegator {
    error AlreadySet();
    error NotSlasher();
    error NotNetwork();
    error NotVault();
    error ExceedsMaxNetworkLimit();

    struct InitParams {
        address vault;
    }

    event SetMaxNetworkLimit(address indexed network, uint256 amount);

    event SetNetworkLimit(address indexed network, uint256 amount);

    event SetOperatorNetworkLimit(address indexed network, address indexed operator, uint256 amount);

    function NETWORK_LIMIT_SET_ROLE() external view returns (bytes32);

    function OPERATOR_NETWORK_LIMIT_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get the network registry's address.
     * @return address of the network registry
     */
    function NETWORK_REGISTRY() external view returns (address);

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    function OPERATOR_VAULT_OPT_IN_SERVICE() external view returns (address);

    function OPERATOR_NETWORK_OPT_IN_SERVICE() external view returns (address);

    function networkLimitIn(address network, uint48 duration) external view returns (uint256);

    function networkLimit(address network) external view returns (uint256);

    function totalOperatorNetworkLimitIn(address network, uint48 duration) external view returns (uint256);

    function totalOperatorNetworkLimit(address network) external view returns (uint256);

    function operatorNetworkLimitIn(
        address network,
        address operator,
        uint48 duration
    ) external view returns (uint256);

    function operatorNetworkLimit(address network, address operator) external view returns (uint256);

    function setMaxNetworkLimit(address network, uint256 amount) external;

    function setNetworkLimit(address network, uint256 amount) external;

    function setOperatorNetworkLimit(address network, address operator, uint256 amount) external;
}