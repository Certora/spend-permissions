import "summary/ERC20s_CVL.spec"; 

using Helper as helper;

methods {
	// returns a non deterministic value for each call 
	function _.isValidSignatureNowAllowSideEffects(address account, bytes32 hash, bytes signature) external => NONDET;
    function _.execute(address target, uint256 value, bytes data) external => NONDET;
	function getBatchHash(SpendPermissionManager.SpendPermissionBatch memory spendPermissionBatch) internal  returns (bytes32) => NONDET; 
    // An optimistic dispatcher can be used to enforce resolving all unresolved calls to a specific method.
    // Be aware: In case the method C.foo(uint) doesn't exist or the sighash doesn't match, this create vacuity.
    unresolved external in _.supportsERC165InterfaceUnchecked(address, bytes4) => DISPATCH [
    ] default NONDET;


    //envfree functions
    function isApproved(SpendPermissionManager.SpendPermission) external returns(bool) envfree;
    function Helper.getBytesHash(bytes) external returns (bytes32) envfree;

    // summarized functions
    function getHash(SpendPermissionManager.SpendPermission memory spendPermission) internal returns (bytes32) => getHash_CVL(spendPermission); 
}



// represent a unique and deterministic hash for SpendPermission
ghost uniqueHash(address,address,address,uint160,uint48,uint48,uint48,uint256,bytes32) returns bytes32;

function hashIsDeterministic(SpendPermissionManager.SpendPermission spendPermission1, SpendPermissionManager.SpendPermission spendPermission2) {
    
    require(getHash_CVL(spendPermission1) == getHash_CVL(spendPermission2) =>
            (spendPermission1.account == spendPermission2.account &&
             spendPermission1.spender == spendPermission2.spender &&
             spendPermission1.token == spendPermission2.token && 
             spendPermission1.allowance == spendPermission2.allowance && 
             spendPermission1.period == spendPermission2.period && 
             spendPermission1.start == spendPermission2.start && 
             spendPermission1.end == spendPermission2.end && 
             spendPermission1.salt == spendPermission2.salt &&
             spendPermission1.extraData == spendPermission2.extraData));
    require helper.getBytesHash(spendPermission1.extraData) == helper.getBytesHash(spendPermission2.extraData) =>
            spendPermission1.extraData == spendPermission2.extraData; 
    }

function getHash_CVL(SpendPermissionManager.SpendPermission spendPermission) returns bytes32 {
    return uniqueHash(spendPermission.account, spendPermission.spender, spendPermission.token, 
                        spendPermission.allowance, spendPermission.period, spendPermission.start, 
                        spendPermission.end, spendPermission.salt, helper.getBytesHash(spendPermission.extraData));
}


// valid state
// lastUpdatedPeriod in not in the future
invariant updatePeriod(SpendPermissionManager.SpendPermission spendPermission, env e)
    getLastUpdatedPeriod(e, spendPermission).start <= getCurrentPeriod(e, spendPermission).start {

        preserved  spend(SpendPermissionManager.SpendPermission spendPermission_processed, uint160 value) with (env e1) {
            hashIsDeterministic(spendPermission, spendPermission_processed);
            
        }
        preserved spendWithWithdraw(SpendPermissionManager.SpendPermission spendPermission_processed, uint160 value, MagicSpend.WithdrawRequest w)  with (env e2) {
            hashIsDeterministic(spendPermission, spendPermission_processed);
        }
    }
   
     


// variable transition 
// _isApproved[hash] is updated only be the account 
rule changeToIsApproved(method f) {
    SpendPermissionManager.SpendPermission spendPermission;
    bool before = isApproved(spendPermission);
    env e;
    calldataarg args;
    f(e,args);
    bool after = isApproved(spendPermission);
    assert after != before => e.msg.sender == spendPermission.account;
}
