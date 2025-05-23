
/***

Examples of rules and CVL features for SpendPermissionManager.getHash()
to run this spec:

certoraRun certora/conf/getHash.conf 



This file contains unit uest rules for getHash.
Here we prove properties of getHash function
which are assumed in the verification of SpendPermissionManager

The rules are in a separate file to avoid any summarization 
*/ 


// same hash for the same structure only 
rule getHashUniqueness() {
	env e;
	SpendPermissionManager.SpendPermission spendPermission1;
	SpendPermissionManager.SpendPermission spendPermission2;

	assert getHash(e,spendPermission1) == getHash(e,spendPermission2) =>
		(
			spendPermission1.account ==  spendPermission2.account  &&
			spendPermission1.spender ==  spendPermission2.spender  &&
			spendPermission1.token ==  spendPermission2.token  &&
			spendPermission1.allowance ==  spendPermission2.allowance  &&
			spendPermission1.period ==  spendPermission2.period  &&
			spendPermission1.start ==  spendPermission2.start  &&
			spendPermission1.end ==  spendPermission2.end  &&
			spendPermission1.salt ==  spendPermission2.salt  &&
			spendPermission1.extraData ==  spendPermission2.extraData  
		);
}

// Deterministic on the SpendPermission struct only
rule getHashDeterministic() {
	env e1;
	env e2;
	SpendPermissionManager.SpendPermission spendPermission;
	assert getHash(e1,spendPermission) == getHash(e2,spendPermission);
}