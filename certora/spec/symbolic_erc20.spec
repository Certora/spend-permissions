import "summary/ERC20s_CVL.spec"; 

methods {
	// returns a non deterministic value for each call 
	function _.isValidSignatureNowAllowSideEffects(address account, bytes32 hash, bytes signature) external => NONDET;
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



rule decreaseInERC20(method f, address user, address token) {
   
	require user != currentContract;
	// call cvl representation of balanceof 
    uint256 before = tokenBalanceOf(token, user);

    env e;
	calldataarg arg;
    f(e, arg);

    uint256 after = tokenBalanceOf(token, user);

    assert after >= before ||  false ; /* fill in cases eth can decrease */ 

} 


rule changeToTwoTokens(method f, address user, address token1, address token2) {
   
	require user != currentContract;
	require token1 != token2;
	// call cvl representation of balanceof 
    uint256 before_t1 = tokenBalanceOf(token1, user);
	uint256 before_t2 = tokenBalanceOf(token2, user);

    env e;
	calldataarg arg;
    f(e, arg);

    uint256 after_t1 = tokenBalanceOf(token1, user);
	uint256 after_t2 = tokenBalanceOf(token2, user);

    assert !(after_t1 != before_t1 &&  after_t2 != before_t2) ;

} 