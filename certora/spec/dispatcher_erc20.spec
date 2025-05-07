using ERC20 as erc20;

methods {
    function _.name() external => DISPATCHER(true);
    function _.symbol() external => DISPATCHER(true);
    function _.decimals() external => DISPATCHER(true);
    function _.totalSupply() external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
    function _.allowance(address,address) external => DISPATCHER(true);
    function _.approve(address,uint256) external => DISPATCHER(true);
    function _.transfer(address,uint256) external => DISPATCHER(true);
    function _.transferFrom(address,address,uint256) external => DISPATCHER(true);

	
	// returns a non deterministic value for each call 
	function _.isValidSignatureNowAllowSideEffects(address account, bytes32 hash, bytes signature) external => NONDET;


	function erc20.balanceOf(address) external returns (uint256) envfree;

	function getHash(SpendPermissionManager.SpendPermission memory spendPermission) internal returns (bytes32) => NONDET; 
	function getBatchHash(SpendPermissionManager.SpendPermissionBatch memory spendPermissionBatch) internal  returns (bytes32) => NONDET; 
}

/* 
	Property: Find and show a path for each method.
*/
rule reachability(method f)
{
	env e;
	calldataarg args;
	f(e,args);
	satisfy true;
}


rule decreaseInERC20(method f, address user) {
   
	require user != currentContract;
    uint256 before = erc20.balanceOf(user);

    env e;
	calldataarg arg;
    f(e, arg);

    uint256 after = erc20.balanceOf(user);

    assert after >= before ||  false ; /* fill in cases eth can decrease */ 

} 