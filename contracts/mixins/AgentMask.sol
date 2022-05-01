// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.4;
pragma experimental ABIEncoderV2;

import "./StorageLayout.sol";
import "../interfaces/ICrocCondOracle.sol";

/* @title Agent mask mixin.
 * @notice Maps and manages surplus balances, nonces, and external router approvals
 *         based on the wallet addresses of end-users. */
contract AgentMask is StorageLayout {

    /* @notice Standard re-entrant gate for an unprivileged order called directly
     *         by the user. */
    modifier reEntrantLock() {
        require(lockHolder_ == address(0));
        lockHolder_ = msg.sender;
        _;
        lockHolder_ = address(0);
    }

    /* @notice Re-entrant gate for privileged protocol authority commands. */
    modifier protocolOnly (bool sudo) {
        require(msg.sender == authority_ && lockHolder_ == address(0));
        lockHolder_ = msg.sender;
        sudoMode_ = sudo;
        _;
        lockHolder_ = address(0);
        sudoMode_ = false;
    }

    /* @notice Re-entrant gate for an order called by external router on behalf of a
     *         third party client. Requires the user to have previously approved the 
     *         router.
     *
     * @param client The client who's order the router is calling on behalf of.
     * @param salt   The approval slot salt to check the user's approval. Allows for a
     *               user to approve the same router with diferent command sub-types. */
    modifier reEntrantApproved (address client, uint256 salt) {
        casAgent(client, msg.sender, salt);
        require(lockHolder_ == address(0));
        lockHolder_ = client;
        _;
        lockHolder_ = address(0);
    }

    /* @notice Re-entrant gate for a relayer calling an order that was signed off-chain
     *         using the EIP-712 standard. */
    modifier reEntrantAgent (CrocRelayerCall memory call,
                             bytes calldata signature) {
        require(lockHolder_ == address(0));
        lockHolder_ = lockSigner(call, signature);
        _;
        lockHolder_ = address(0);
    }

    struct CrocRelayerCall {
        uint16 callpath;
        bytes cmd;
        bytes conds;
        bytes tip;
    }

    /* @notice Given the order, evaluation conditionals, and off-chain signature, recovers
     *         the client address if valid or reverts the transactions. */
    function lockSigner (CrocRelayerCall memory call,
                         bytes calldata signature) private returns (address client) {
        client = verifySignature(call, signature);
        checkRelayConditions(client, call.conds);
    }

    /* @notice Verifies that the conditions signed by the user are met at evaluation time,
     *         and if necessary increments the nonce. 
     *
     * @param client The client who's order is being evaluated on behalf of.
     * @param deadline The deadline (in block time) that the order must be evaluated by.
     * @param alive    The live time (in block time) that the order cannot be evaluated
     *                 before.
     * @param salt     A salt to apply when checking the nonce. Allows users to sign
     *                 an arbitrary number of multiple nonce tracks, so they don't have
     *                 to wait for unrelated orders.
     * @param nonce    The replay-attack prevention nonce. Two orders with the same salt
     *                 and nonce cannot be evaluated (unless the user explicitly resets
     *                 the nonce). A nonce cannot be evaluated until prior orders at
     *                 lower nonces haven been successfully evaluated.
     * @param relayer  Address of the relayer the user requires to evaluate the order.
     *                 Must match either msg.sender or tx.origin. If zero, the order
     *                 does not require a specific relayer. */
    function checkRelayConditions (address client, bytes memory conds) internal {
        (uint48 deadline, uint48 alive, bytes32 salt, uint32 nonce,
         address relayer)
            = abi.decode(conds, (uint48, uint48, bytes32, uint32, address));
        
        require(block.timestamp <= deadline);
        require(block.timestamp >= alive);
        require(relayer == address(0) || relayer == msg.sender || relayer == tx.origin);
        casNonce(client, salt, nonce);
    }

    /* @notice Verifies the supplied signature matches the EIP-712 compatible data. */
    function verifySignature (CrocRelayerCall memory call,
                              bytes calldata signature)
        internal view returns (address client) {
        (uint8 v, bytes32 r, bytes32 s) =
            abi.decode(signature, (uint8, bytes32, bytes32));
        bytes32 checksum = checksumHash(call);
        client = ecrecover(checksum, v, r, s);
        require(client != address(0));
    }
    
    /* @notice Calculates the EIP-712 hash to check the signature against. */
    function checksumHash (CrocRelayerCall memory call)
        private view returns (bytes32) {
        bytes32 hash = contentHash(call);
        return keccak256(abi.encodePacked
                         ("\x19\x01", domainHash(), hash));
    }

    /* @notice Calculates the EIP-712 typedStruct hash. */
    function contentHash (CrocRelayerCall memory call)
        private pure returns (bytes32) {
        return keccak256(
            abi.encode
            (keccak256
             ("CrocRelayerCall(uint8 callpath,bytes cmd,bytes conds,bytes tip)"),
             call.callpath,
             keccak256(call.cmd),
             keccak256(call.conds),
             keccak256(call.tip)));
    }

    /* @notice Calculates the EIP-712 domain hash. */
    function domainHash() private view returns (bytes32) {
        return keccak256(
            abi.encode
            (keccak256(
                "EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
             keccak256("CrocSwap"),
             block.chainid,
             address(this)));
    }

    /* @notice Returns the payer and receiver of any settlement collateral flows.
     * @return debit The address that will be paying any debits to the pool.
     * @return credit The address that will receive any credits from the pool. */
    function agentsSettle() internal view returns (address debit, address credit) {
        (debit, credit) = (lockHolder_, lockHolder_);
    }


    /* @notice Approves an external router or agent to act on a user's behalf.
     * @param router The address of the external agent.
     * @param nCalls The number of calls the external router is authorized to make. Set
     *               to uint32.max for unlimited.
     * @param salt An arbitrary number corresponding to a specific call track. When the
     *             external agent calls the dex on the user's behalf it will supply this
     *             number and nCalls will be checked specifically against it. Depending
     *             on implementation, this allows users to authorize routers to make
     *             certain types of calls but not others. */
    function approveAgent (address router, uint32 nCalls, uint256 salt) internal {
        bytes32 key = agentKey(lockHolder_, router, salt);
        UserBalance storage bal = userBals_[key];
        bal.agentCallsLeft_ = nCalls;
    }

    /* @notice Sets the nonce index related to EIP-712 off-chain calls. 
     * @param nonceSalt The nonce system is multi-dimensional, which allows relayers to
     *                  pass along arbitrary ordered messages when they come from 
     *                  unrelated streams. This value corresponds to the specific nonce
     *                  dimension.
     * @param nonce The nonce index value the nonce will be reset to. */
    function resetNonce (bytes32 nonceSalt, uint32 nonce) internal {
        UserBalance storage bal = userBals_[nonceKey(lockHolder_, nonceSalt)];
        bal.nonce_ = nonce;
    }

    /* @notice Same as resetNonce but conditions on the successful call return to an 
     *         external oracle. Useful for certain times that a user wants to pre-sign
     *         a transaction, but not let it be executable unless an arbitrary condition
     *         is met. 
     * @param nonceSalt The nonce system is multi-dimensional, which allows relayers to
     *                  pass along arbitrary ordered messages when they come from 
     *                  unrelated streams. This value corresponds to the specific nonce
     *                  dimension.
     * @param nonce The nonce index value the nonce will be reset to.
     * @param oracle The address of the external oracle (must conform to ICrocNonceOracle
     *               interface.
     * @param args Arbitrary calldata passed to the oracle condition call. */
    function resetNonceCond (bytes32 salt, uint32 nonce, address oracle,
                             bytes memory args) internal {
        bool canProceed = ICrocNonceOracle(oracle).checkCrocNonceSet
            (lockHolder_, salt, nonce, args);
        require(canProceed, "ON");
        resetNonce(salt, nonce);
    }

    /* @notice Flat call that checks an external oracle and reverts the transaction if the
     *         oracle call fails. Useful in a multicall context, where we want to pre-
     *         condition on some external requirement.
     * @param oracle The address of the external oracle (must conform to ICrocCondOracle
     *               interface.
     * @param args Arbitrary calldata passed to the oracle condition call. */
    function checkGateOracle (address oracle, bytes memory args) internal {
        bool canProceed = ICrocCondOracle(oracle).checkCrocCond
            (lockHolder_, args);
        require(canProceed, "OG");
    }

    /* @notice Compare-and-swap the nCalls on a single external agent call. Checks that
     *         the agent is authorized to perform another call, and if so decrements the
     *         number of remaining calls.
     * @param client The client the agent is making the call on behalf of.
     * @param agent The address of the external agent making the call.
     * @param salt The multidimensional nonce dimension the call is being applied to. */
    function casAgent (address client, address agent, uint256 salt) internal {
        UserBalance storage bal = userBals_[agentKey(client, agent, salt)];
        if (bal.agentCallsLeft_ < type(uint32).max) {
            require(bal.agentCallsLeft_ > 0);
            --bal.agentCallsLeft_;
        }
    }

    /* @notice Compare-and-swap the nonce on a single EIP-712 signed transaction. Checks
     *         that the nonce matches the current nonce for the user/salt, and atomically
     *         increments the nonce.
     * @param client The client the agent is making the call on behalf of.
     * @param salt The multidimensional nonce dimension the call is being applied to.
     * @param nonce The nonce the EIP-712 message is signed for. This must match the 
     *              current nonce or the transaction will fail. */
    function casNonce (address client, bytes32 nonceSalt, uint32 nonce) internal {
        UserBalance storage bal = userBals_[nonceKey(client, nonceSalt)];
        require(bal.nonce_ == nonce);
        ++bal.nonce_;
    }

    /* @notice Called within the context of an EIP-712 transaction, where the underlying
     *         client pays the relayer for having mined the transaction. (If the cmd byte
     *         data is empty, no tip is paid).
     *
     * @dev Thie call will always occur at the *end* of a transaction. So the user must 
     *      have sufficient balance in their surplus collateral to cover the tip by the
     *      completion of the transaction.
     *
     * @param token The token the tip is being paid in. This will always be paid from the
     *              user's surplus collateral balance.
     * @param tip The amount the user is paying in tip. If protocol fee is turned on this
     *            is the *total* amount paid. The relayer will receive this less protocol
     *            fee. Tip can also be set to uint128.max, and will pay the full amount
     *            of the client's surplus collateral balance.
     * @param recv The receiver of the tip. This will always be paid to this account's
     *             surplus collateral balance. Also supports generic magic values for 
     *             generic relayer payment:
     *                 0x10 - Paid to the msg.sender, regardless of who made the dex call
     *                 0x20 - Paid to the tx.origin, regardless of who sent tx. */
    function tipRelayer (bytes memory tipCmd) internal {
        if (tipCmd.length == 0) { return; }
        
        (address token, uint128 tip, address recv) =
            abi.decode(tipCmd, (address, uint128, address));
        
        recv = maskTipRecv(recv);
        bytes32 fromKey = tokenKey(lockHolder_, token);
        bytes32 toKey = tokenKey(recv, token);
        
        if (tip == type(uint128).max) {
            tip = userBals_[fromKey].surplusCollateral_;
        }
        require(userBals_[fromKey].surplusCollateral_ >= tip);
        
        uint128 protoFee = tip * relayerTakeRate_ / 256;
        uint128 relayerTip = tip - protoFee;
        
        userBals_[fromKey].surplusCollateral_ -= tip;
        userBals_[toKey].surplusCollateral_ += relayerTip;
        if (protoFee > 0) {
            feesAccum_[token] += protoFee;
        }
    }

    address constant MAGIC_SENDER_TIP = address(256);
    address constant MAGIC_ORIGIN_TIP = address(512);

    /* @notice Converts the user's tip recv argument to the actual address to be paid.
     *         In practice this means that the magic values for msg.sender and tx.origin
     *         are converted to those value's actual address for the transaction. */
    function maskTipRecv (address recv) view private returns (address) {
        if (recv == MAGIC_SENDER_TIP) {
            recv = msg.sender;
        } else if (recv == MAGIC_ORIGIN_TIP) {
            recv = tx.origin;
        } 
        return recv;
    }

    /* @notice Given a user address and a salt returns a new virtualized user address. 
     *         Useful when we want multiple synthetic accounts tied to a single address.*/
    function virtualizeUser (address client, uint256 salt) internal pure returns
        (address) {
        if (salt == 0) { return client; }
        else {
            return PoolSpecs.virtualizeAddress(client, salt);
        }
    }

    /* @notice Returns the user balance key given a user account an an inner salt. */
    function nonceKey (address user, bytes32 innerKey) pure internal returns (bytes32) {
        return keccak256(abi.encode(user, innerKey));
    }

    /* @notice Returns a token balance key given a user and token address. */
    function tokenKey (address user, address token) pure internal returns (bytes32) {
        return keccak256(abi.encode(user, token));
    }

    /* @notice Returns a token balance key given a user, token and an arbitrary salt. */
    function tokenKey (address user, address token, uint256 salt) pure internal
        returns (bytes32) {
        return tokenKey(user, PoolSpecs.virtualizeAddress(token, salt));
    }

    /* @notice Returns an agent key given a user, an agent address and an arbitrary 
     *         salt. */
    function agentKey (address user, address agent, uint256 salt) pure internal
        returns (bytes32) {
        if (salt == 0) {
            return keccak256(abi.encode(user, agent));
        } else {
            return keccak256(abi.encode(user, PoolSpecs.virtualizeAddress(agent, salt)));
        }
    }

}
