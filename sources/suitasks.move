module suitasks::task {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::balance::{Self, Balance};
    use std::string::{Self, String};
    use std::option::{Self, Option};

    // Error codes
    const ETaskAlreadyCompleted: u64 = 0;
    const EInsufficientReward: u64 = 1;
    const ENotCreator: u64 = 2;
    const ENoSolver: u64 = 3;
    const ENotSolver: u64 = 4;
    const ETaskNotInProgress: u64 = 5;
    const ETaskNotPendingReview: u64 = 6;
    const ETaskCannotBeCancelled: u64 = 7;
    const EWorkAlreadySubmitted: u64 = 8;

    // Task status enum
    const STATUS_AVAILABLE: u8 = 0;
    const STATUS_IN_PROGRESS: u8 = 1;
    const STATUS_PENDING_REVIEW: u8 = 2;
    const STATUS_COMPLETED: u8 = 3;
    const STATUS_CANCELLED: u8 = 4;

    // Task struct: Represents a task with reward and status
    public struct Task has key, store {
        id: UID,
        description: String,
        reward: Balance<SUI>,
        creator: address,
        solver: Option<address>,
        status: u8,
        deadline: u64, // Epoch timestamp
        work_submission: Option<String>,
        rejection_reason: Option<String>,
    }

    // PlatformConfig: Stores admin and fee details
    public struct PlatformConfig has key {
        id: UID,
        admin: address,
        fee_percentage: u64, // e.g., 300 for 3%
        fee_balance: Balance<SUI>,
    }

    // Initialize platform (run once by admin)
    fun init(ctx: &mut TxContext) {
        let config = PlatformConfig {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            fee_percentage: 300, // 3% fee
            fee_balance: balance::zero<SUI>(),
        };
        transfer::share_object(config);
    }

    // Create a task with description, reward, and deadline
    public entry fun create_task(description: vector<u8>, reward: Coin<SUI>, deadline: u64, ctx: &mut TxContext) {
        let reward_value = coin::value(&reward);
        assert!(reward_value >= 1000, EInsufficientReward); // Min 0.001 SUI
        assert!(deadline > tx_context::epoch(ctx), ETaskAlreadyCompleted); // Deadline in future
        let task = Task {
            id: object::new(ctx),
            description: string::utf8(description),
            reward: coin::into_balance(reward),
            creator: tx_context::sender(ctx),
            solver: option::none<address>(),
            status: STATUS_AVAILABLE,
            deadline,
            work_submission: option::none<String>(),
            rejection_reason: option::none<String>(),
        };
        transfer::share_object(task);
    }

    // Accept a task as solver
    public entry fun accept_task(task: &mut Task, ctx: &mut TxContext) {
        assert!(task.status == STATUS_AVAILABLE, ETaskAlreadyCompleted);
        assert!(option::is_none(&task.solver), ENoSolver);
        assert!(tx_context::epoch(ctx) <= task.deadline, ETaskAlreadyCompleted);
        task.solver = option::some(tx_context::sender(ctx));
        task.status = STATUS_IN_PROGRESS;
    }

    // Submit work as solver
    public entry fun submit_work(task: &mut Task, work_proof: vector<u8>, ctx: &mut TxContext) {
        assert!(task.status == STATUS_IN_PROGRESS, ETaskNotInProgress);
        assert!(option::is_some(&task.solver), ENoSolver);
        let solver = *option::borrow(&task.solver);
        assert!(tx_context::sender(ctx) == solver, ENotSolver);
        assert!(option::is_none(&task.work_submission), EWorkAlreadySubmitted);
        
        task.work_submission = option::some(string::utf8(work_proof));
        task.status = STATUS_PENDING_REVIEW;
    }

    // Review and approve work (creator approves)
    public entry fun approve_work(task: &mut Task, config: &mut PlatformConfig, ctx: &mut TxContext) {
        assert!(task.status == STATUS_PENDING_REVIEW, ETaskNotPendingReview);
        assert!(tx_context::sender(ctx) == task.creator, ENotCreator);
        assert!(option::is_some(&task.solver), ENoSolver);
        
        task.status = STATUS_COMPLETED;
        let solver = *option::borrow(&task.solver);
        let reward_value = balance::value(&task.reward);
        let fee = (reward_value * config.fee_percentage) / 10000;
        let solver_amount = reward_value - fee;

        // Transfer fee to platform
        let fee_coin = coin::take(&mut task.reward, fee, ctx);
        balance::join(&mut config.fee_balance, coin::into_balance(fee_coin));

        // Transfer reward to solver
        let solver_coin = coin::take(&mut task.reward, solver_amount, ctx);
        transfer::public_transfer(solver_coin, solver);
    }

    // Review and reject work (creator rejects)
    public entry fun reject_work(task: &mut Task, reason: vector<u8>, ctx: &mut TxContext) {
        assert!(task.status == STATUS_PENDING_REVIEW, ETaskNotPendingReview);
        assert!(tx_context::sender(ctx) == task.creator, ENotCreator);
        
        task.status = STATUS_IN_PROGRESS;
        task.work_submission = option::none<String>();
        task.rejection_reason = option::some(string::utf8(reason));
    }

    // Cancel task (only available tasks can be cancelled)
    public entry fun cancel_task(task: &mut Task, ctx: &mut TxContext) {
        assert!(task.status == STATUS_AVAILABLE, ETaskCannotBeCancelled);
        assert!(tx_context::sender(ctx) == task.creator, ENotCreator);
        
        task.status = STATUS_CANCELLED;
        let reward_amount = balance::value(&task.reward);
        let refund_coin = coin::take(&mut task.reward, reward_amount, ctx);
        transfer::public_transfer(refund_coin, task.creator);
    }

    // Legacy complete_task function (kept for backward compatibility)
    public entry fun complete_task(task: &mut Task, config: &mut PlatformConfig, ctx: &mut TxContext) {
        // This now just calls approve_work for backward compatibility
        approve_work(task, config, ctx);
    }

    // Admin withdraws fees
    public entry fun withdraw_fees(config: &mut PlatformConfig, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.admin, ENotCreator);
        let fee_amount = balance::value(&config.fee_balance);
        let fee_coin = coin::take(&mut config.fee_balance, fee_amount, ctx);
        transfer::public_transfer(fee_coin, config.admin);
    }

    // Getter for task details (for UI)
    public fun get_task_details(task: &Task): (String, u64, address, Option<address>, u8, u64, Option<String>, Option<String>) {
        (
            task.description,
            balance::value(&task.reward),
            task.creator,
            task.solver,
            task.status,
            task.deadline,
            task.work_submission,
            task.rejection_reason
        )
    }

    // Helper functions to get status as string
    public fun status_to_string(status: u8): String {
        if (status == STATUS_AVAILABLE) {
            string::utf8(b"Available")
        } else if (status == STATUS_IN_PROGRESS) {
            string::utf8(b"In Progress")
        } else if (status == STATUS_PENDING_REVIEW) {
            string::utf8(b"Pending Review")
        } else if (status == STATUS_COMPLETED) {
            string::utf8(b"Completed")
        } else if (status == STATUS_CANCELLED) {
            string::utf8(b"Cancelled")
        } else {
            string::utf8(b"Unknown")
        }
    }
}