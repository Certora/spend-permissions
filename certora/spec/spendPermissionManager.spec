/***

Examples of rules and CVL features for SpendPermissionManager
to run this spec:

certoraRun certora/conf/spendPermissionManager.conf 

To run mutations:
certoraMutate certora/conf/spendPermissionManager.conf  

**/

import "summary/ERC20s_CVL.spec"; 

using Helper as helper;

methods {
	// returns a non deterministic value for each call 
    // these are unsafe assumptions as this functions have side effects
	function _.isValidSignatureNowAllowSideEffects(address account, bytes32 hash, bytes signature) external => NONDET;
    // assume the low level call in supportsERC165InterfaceUnchecked has no effect
    unresolved external in _.supportsERC165InterfaceUnchecked(address, bytes4) => DISPATCH [
    ] default NONDET;



    /* summarizing getBatchHash as nondet is an over approximation, there are no side effect and all possible return value are taken into account. However it might cause infeasible counter examples 
    */
	function getBatchHash(SpendPermissionManager.SpendPermissionBatch memory spendPermissionBatch) internal  returns (bytes32) => NONDET; 


    
    //envfree functions
    function isApproved(SpendPermissionManager.SpendPermission) external returns(bool) envfree;
    function Helper.getBytesHash(bytes) external returns (bytes32) envfree;

    // summarized functions
    function getHash(SpendPermissionManager.SpendPermission memory spendPermission) internal returns (bytes32) => getHash_CVL(spendPermission); 

    // only track that execute was called (ignoring side effect)
    function _.execute(address target, uint256 value, bytes data) external => setExecutedCalled() expect void;
}



// represent a unique and deterministic hash for SpendPermission
/* ghosts are over primitive types, so instead of bytes, the hash of the bytes is used.
A ghost definition provides a deterministic value,  each SpendPermission has a single hash (but not necessary unique)*/
ghost uniqueHash(address, /* account */
                address, /* spender */ 
                address, /* token */
                uint160, /* allowance */ 
                uint48, /* period */ 
                uint48, /* start */
                uint48, /* end */ 
                uint256,/* salt */
                bytes32 /* keccak256(extraData) */) 
        returns bytes32;

/* a CVL function to assume the uniqueness, the hash is the same only for the exact same SpendPermission 
*/
// note that here we assume no hash-collision 
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
    }

function getHash_CVL(SpendPermissionManager.SpendPermission spendPermission) returns bytes32 {
    return uniqueHash(spendPermission.account, spendPermission.spender, spendPermission.token, 
                        spendPermission.allowance, spendPermission.period, spendPermission.start, 
                        spendPermission.end, spendPermission.salt, helper.getBytesHash(spendPermission.extraData));
}

/*********** valid state properties *****************/
// lastUpdatedPeriod in not in the future
invariant updatePeriod(SpendPermissionManager.SpendPermission spendPermission, env e)
    getLastUpdatedPeriod(e, spendPermission).start <= getCurrentPeriod(e, spendPermission).start  {

        preserved spend(SpendPermissionManager.SpendPermission spendPermission_processed, uint160 value) with (env e1) {
            hashIsDeterministic(spendPermission, spendPermission_processed);
        }

        preserved spendWithWithdraw(SpendPermissionManager.SpendPermission spendPermission_processed, uint160 value, MagicSpend.WithdrawRequest w)  with (env e1) {
            hashIsDeterministic(spendPermission, spendPermission_processed);
        }
    } 
   



/*********** variable transition *****************/
// _isApproved[hash] is updated only be the account (not a correct property)
rule changeToIsApproved(method f) {
    SpendPermissionManager.SpendPermission spendPermission;
    bool before = isApproved(spendPermission);
    env e;
    calldataarg args;
    f(e,args);
    bool after = isApproved(spendPermission);
    assert after != before => e.msg.sender == spendPermission.account;
}


// update to getLastUpdatedPeriod implies execute() was called 

// flag to track updates (sstore operation) to getLastUpdatedPeriod.spec
ghost bool getLastUpdatedPeriod_store;
// flag to track that execute was called
ghost bool executeCalled;

// the summary function for execute(), setting the flag to true
function setExecutedCalled()  {
    executeCalled = true;
}

hook Sstore _lastUpdatedPeriod[KEY bytes32 hash].spend uint160 newValue (uint160 oldValue) {
    // Update the ghost. ignore the value
    getLastUpdatedPeriod_store = true;
}

// getLastUpdatedPeriod is updated only is execute was called
// todo: can be made stronger, which hash is updated with regard to the call 
rule getLastUpdatedPeriodImpliesExecute(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    require !getLastUpdatedPeriod_store && !executeCalled;
    f(e,args);
    assert getLastUpdatedPeriod_store => executeCalled;
}

// More properties:
// for a given permission spend in PeriodSpend le allowance in the isApproved mapping