{{ config(
    schema = 'aztec_v2_ethereum',
    alias = 'daily_estimated_rollup_tvl',
    partition_by = ['date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['symbol', 'token_address', 'date'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "aztec_v2",
                                \'["Henrystats"]\') }}'
    )
}}

with 

rollup_balance_changes as (
  select CAST(t.evt_block_time as date) as date
    , t.symbol
    , t.contract_address as token_address
    , sum(case when t.from_type = 'Rollup' then -1 * value_norm when t.to_type = 'Rollup' then value_norm else 0 end) as net_value_norm
  from {{ref('aztec_v2_ethereum_rollupbridge_transfers')}} t
  where t.from_type = 'Rollup' or t.to_type = 'Rollup'
  group by 1,2,3
)

, token_balances as (
  select date
    , symbol
    , token_address
    , sum(net_value_norm) over (partition by symbol,token_address order by date asc rows between unbounded preceding and current row) as balance
    , lead(date, 1) over (partition by token_address order by date) as next_date
  from rollup_balance_changes
)

, day_series as (
  SELECT explode(sequence(CAST('2022-06-06' as date), CAST(NOW() as date), interval '1 Day')) as date 
)

, token_balances_filled as (
  select d.date
    , b.symbol
    , b.token_address
    , b.balance
  from day_series d
  inner join token_balances b
        on d.date >= b.date
        and d.date < coalesce(b.next_date,CAST(NOW() as date) + 1) -- if it's missing that means it's the last entry in the series
)

, token_addresses as (
    SELECT 
        DISTINCT(token_address) as token_address FROM rollup_balance_changes
) 

, token_prices_token as (
    SELECT 
        date_trunc('day', p.minute) as day, 
        p.contract_address as token_address, 
        p.symbol, 
        AVG(p.price) as price
    FROM 
    token_addresses ta 
    INNER JOIN 
        {{ source('prices', 'usd') }} p 
        ON ta.token_address = p.contract_address
        AND p.blockchain = 'ethereum'
        {% if not is_incremental() %}
        AND p.minute >= '{{first_transfer_date}}'
        {% endif %}
        {% if is_incremental() %}
        AND p.minute >= date_trunc("day", now() - interval '1 week')
        {% endif %}
    GROUP BY 1, 2, 3 
)

, token_prices_eth as (
    SELECT 
        date_trunc('day', p.minute) as day, 
        AVG(p.price) as price

    FROM 
        {{ source('prices', 'usd') }} p 
        {% if not is_incremental() %}
        WHERE p.minute >= '{{first_transfer_date}}'
        {% endif %}
        {% if is_incremental() %}
        WHERE p.minute >= date_trunc("day", now() - interval '1 week')
        {% endif %}
        AND p.blockchain = 'ethereum'
        AND p.symbol = 'WETH'
    GROUP BY 1
)

, token_prices as (
    SELECT 
        tt.day, 
        tt.token_address,
        tt.symbol,
        tt.price as price_usd, 
        tt.price/te.price as price_eth,
        te.price as eth_price 
    FROM 
    token_prices_token tt 
    INNER JOIN 
    token_prices_eth te 
        ON tt.day = te.day 
)
, token_tvls as (
  select b.date
    , b.symbol
    , b.token_address
    , b.balance
    , b.balance * COALESCE(p.price_usd, bb.eth_price) as tvl_usd
    , b.balance * COALESCE(p.price_eth, 1) as tvl_eth
  from token_balances_filled b
  inner join token_prices p on b.date = p.day and b.token_address = p.token_address
  LEFT JOIN token_prices bb on b.date = bb.day AND b.token_address = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' -- using this to get price for missing ETH token 
  
)
select * from token_tvls
;