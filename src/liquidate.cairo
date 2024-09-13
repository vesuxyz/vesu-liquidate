use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use starknet::{ContractAddress};

#[derive(Serde, Copy, Drop)]
pub struct RouteNode {
    pub pool_key: PoolKey,
    pub sqrt_ratio_limit: u256,
    pub skip_ahead: u128,
}

#[derive(Serde, Copy, Drop)]
pub struct TokenAmount {
    pub token: ContractAddress,
    pub amount: i129,
}

#[derive(Serde, Drop, Clone)]
pub struct Swap {
    pub route: Array<RouteNode>,
    pub token_amount: TokenAmount,
    pub limit_amount: u128,
}

#[derive(Serde, Drop, Clone)]
pub struct LiquidateParams {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub recipient: ContractAddress,
    pub min_collateral_to_receive: u256,
    pub debt_to_repay: u256,
    pub liquidate_swap: Swap,
    pub withdraw_swap: Swap,
}

#[derive(Serde, Copy, Drop)]
pub struct LiquidateResponse {
    pub liquidated_collateral: u256,
    pub repaid_debt: u256,
    pub residual_collateral: u256,
    pub residual_token: ContractAddress
}

#[starknet::interface]
pub trait ILiquidate<TContractState> {
    fn liquidate(ref self: TContractState, params: LiquidateParams) -> LiquidateResponse;
}

#[starknet::contract]
pub mod Liquidate {
    use starknet::{ContractAddress, get_contract_address};
    use core::num::traits::{Zero};

    use ekubo::{
        components::{shared_locker::{consume_callback_data, handle_delta, call_core_with_callback}},
        interfaces::{
            core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters},
            erc20::{IERC20Dispatcher, IERC20DispatcherTrait}
        },
        types::{i129::{i129, i129Trait, i129_new}, delta::{Delta}, keys::{PoolKey}}
    };

    use vesu::{
        singleton::{ISingleton, ISingletonDispatcher, ISingletonDispatcherTrait},
        data_model::{LiquidatePositionParams, Amount, UpdatePositionResponse},
        extension::components::position_hooks::LiquidationData, common::{i257, i257_new}
    };

    use super::{ILiquidate, RouteNode, TokenAmount, Swap, LiquidateParams, LiquidateResponse};

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidatePosition {
        #[key]
        pool_id: felt252,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        residual: u256,
        collateral_delta: u256,
        debt_delta: u256
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        LiquidatePosition: LiquidatePosition
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, core: ICoreDispatcher, singleton: ISingletonDispatcher
    ) {
        self.core.write(core);
        self.singleton.write(singleton);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn swap(ref self: ContractState, swap: Swap) -> (TokenAmount, TokenAmount) {
            let core = self.core.read();

            let mut route = swap.route;
            let mut token_amount = swap.token_amount;

            // we track this to know how much to pay in the case of exact input and how much to pull in the case of exact output
            let mut first_swap_amount: Option<TokenAmount> = Option::None;

            loop {
                match route.pop_front() {
                    Option::Some(node) => {
                        assert!(
                            token_amount.token == node.pool_key.token0
                                || token_amount.token == node.pool_key.token1,
                            "invalid-token"
                        );
                        let is_token1 = token_amount.token == node.pool_key.token1;

                        let delta = core
                            .swap(
                                node.pool_key,
                                SwapParameters {
                                    amount: token_amount.amount,
                                    is_token1: is_token1,
                                    sqrt_ratio_limit: node.sqrt_ratio_limit,
                                    skip_ahead: node.skip_ahead,
                                }
                            );

                        if is_token1 {
                            assert!(delta.amount1.mag == token_amount.amount.mag, "partial-swap");
                        } else {
                            assert!(delta.amount0.mag == token_amount.amount.mag, "partial-swap");
                        }

                        if first_swap_amount.is_none() {
                            first_swap_amount =
                                if is_token1 {
                                    Option::Some(
                                        TokenAmount {
                                            token: node.pool_key.token1, amount: delta.amount1
                                        }
                                    )
                                } else {
                                    Option::Some(
                                        TokenAmount {
                                            token: node.pool_key.token0, amount: delta.amount0
                                        }
                                    )
                                }
                        }

                        token_amount =
                            if (is_token1) {
                                TokenAmount { amount: -delta.amount0, token: node.pool_key.token0 }
                            } else {
                                TokenAmount { amount: -delta.amount1, token: node.pool_key.token1 }
                            };
                    },
                    Option::None => { break (); }
                };
            };

            let first = first_swap_amount.unwrap();

            let (input, output) = if !swap.token_amount.amount.is_negative() {
                // exact in: limit_amount is min. amount out
                assert!(token_amount.amount.mag >= swap.limit_amount, "limit-amount-exceeded");
                (first, token_amount)
            } else {
                // exact out: limit_amount is max. amount in
                assert!(token_amount.amount.mag <= swap.limit_amount, "limit-amount-exceeded");
                (token_amount, first)
            };

            (input, output)
        }

        fn liquidate_position(
            ref self: ContractState, liquidate_params: LiquidateParams
        ) -> LiquidateResponse {
            let LiquidateParams { pool_id,
            collateral_asset,
            debt_asset,
            user,
            recipient,
            min_collateral_to_receive,
            mut debt_to_repay,
            mut liquidate_swap,
            mut withdraw_swap } =
                liquidate_params;

            let singleton = self.singleton.read();
            let (_, _, debt) = singleton.position(pool_id, collateral_asset, debt_asset, user);

            // if debt_to_repay is 0 or greater than the debt, repay the full debt
            if debt_to_repay == 0 || debt_to_repay > debt {
                debt_to_repay = debt;
            }

            // flash loan asset to repay the position's debt
            handle_delta(
                self.core.read(),
                debt_asset,
                i129_new(debt_to_repay.try_into().unwrap(), true),
                get_contract_address()
            );

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }
                    .approve(singleton.contract_address, debt),
                "approve-failed"
            );

            let liquidation_data = LiquidationData { min_collateral_to_receive, debt_to_repay };
            let mut data: Array<felt252> = array![];
            Serde::serialize(@liquidation_data, ref data);

            let UpdatePositionResponse { collateral_delta, debt_delta, bad_debt, .. } = self
                .singleton
                .read()
                .liquidate_position(
                    LiquidatePositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        receive_as_shares: false,
                        data: data.span()
                    }
                );

            let debt_paid = debt_delta.abs - bad_debt;

            // - swap collateral asset to debt asset (1.)
            // for repaying an exact amount of debt:
            //   - input token: debt asset and output token: collateral asset, since we specify a negative input amount
            //     of the debt asset (swap direction is reversed)
            assert!(
                liquidate_swap.token_amount.token == debt_asset
                    && liquidate_swap.token_amount.amount == Zero::zero(),
                "invalid-liquidate-swap-config"
            );
            liquidate_swap.token_amount.amount = i129_new(debt_paid.try_into().unwrap(), true);
            let (collateral_amount, debt_amount) = self.swap(liquidate_swap.clone());
            assert!(collateral_amount.token == collateral_asset, "invalid-liquidate-swap-assets");

            // - handleDelta: settle the remaining debt asset flashloan (1.)
            handle_delta(
                self.core.read(),
                debt_amount.token,
                i129_new((debt_to_repay - debt_paid).try_into().unwrap(), false),
                get_contract_address()
            );

            // - handleDelta: settle collateral asset swap (1.)
            handle_delta(
                self.core.read(),
                collateral_amount.token,
                i129_new(collateral_amount.amount.mag, false),
                get_contract_address()
            );

            let residual_collateral = collateral_delta.abs.try_into().unwrap()
                - collateral_amount.amount.mag;

            self
                .emit(
                    LiquidatePosition {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        residual: residual_collateral.into(),
                        collateral_delta: collateral_delta.abs,
                        debt_delta: debt_delta.abs.try_into().unwrap()
                    }
                );

            // avoid withdraw_swap moving error by returning early here
            if withdraw_swap.route.len() == 0 {
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transfer(recipient, residual_collateral.into()),
                    "transfer-failed"
                );
                return LiquidateResponse {
                    liquidated_collateral: collateral_delta.abs,
                    repaid_debt: debt_delta.abs,
                    residual_collateral: residual_collateral.into(),
                    residual_token: collateral_asset
                };
            }

            // - swap residual / margin collateral amount to arbitrary asset and handle delta
            assert!(
                withdraw_swap.token_amount.token == collateral_asset
                    && withdraw_swap.token_amount.amount.mag == 0,
                "invalid-withdraw_swap-config"
            );

            withdraw_swap.token_amount.amount = i129_new(residual_collateral, false);

            // collateral_asset to arbitrary_asset
            // token_amount is always positive, limit_amount is min. amount out:
            let (collateral_margin_amount, out_amount) = self.swap(withdraw_swap.clone());

            handle_delta(
                self.core.read(),
                collateral_margin_amount.token,
                i129_new(collateral_margin_amount.amount.mag, false),
                get_contract_address()
            );
            handle_delta(
                self.core.read(), out_amount.token, i129_new(out_amount.amount.mag, true), recipient
            );

            return LiquidateResponse {
                liquidated_collateral: collateral_delta.abs,
                repaid_debt: debt_delta.abs,
                residual_collateral: out_amount.amount.mag.into(),
                residual_token: out_amount.token
            };
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // asserts that caller is core
            let liquidate_params: LiquidateParams = consume_callback_data(core, data);
            let liquidate_response = self.liquidate_position(liquidate_params);

            let mut data: Array<felt252> = array![];
            Serde::serialize(@liquidate_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl LiquidateImpl of ILiquidate<ContractState> {
        fn liquidate(ref self: ContractState, params: LiquidateParams) -> LiquidateResponse {
            call_core_with_callback(self.core.read(), @params)
        }
    }
}
