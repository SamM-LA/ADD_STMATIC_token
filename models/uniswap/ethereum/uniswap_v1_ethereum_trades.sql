{{ config(
    schema = 'uniswap_v1_ethereum',
    alias = 'trades',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index', 'trace_address'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "uniswap_v1",
                                \'["jeff-dude", "markusbkoch", "masquot", "milkyklim", "0xBoxer", "mewwts", "hagaetc"]\') }}'
    )
}}

{% set project_start_date = '2018-11-01' %}
{% set weth_address = '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2' %}

WITH dexs AS
(
    -- Uniswap v1 TokenPurchase
    SELECT
        t.evt_block_time AS block_time
        ,t.buyer AS taker
        ,'' AS maker
        ,t.tokens_bought AS token_bought_amount_raw
        ,t.eth_sold AS token_sold_amount_raw
        ,NULL AS amount_usd
        ,f.token AS token_bought_address
        ,'{{weth_address}}' AS token_sold_address --Using WETH for easier joining with USD price table
        ,t.contract_address AS project_contract_address
        ,t.evt_tx_hash AS tx_hash
        ,'' AS trace_address
        ,t.evt_index
    FROM
        {{ source('uniswap_ethereum', 'Exchange_evt_TokenPurchase') }} t
    INNER JOIN {{ source('uniswap_ethereum', 'Factory_evt_NewExchange') }} f
        ON f.exchange = t.contract_address
    {% if is_incremental() %}
    WHERE t.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}

    UNION ALL

    -- Uniswap v1 EthPurchase
    SELECT
        t.evt_block_time AS block_time
        ,t.buyer AS taker
        ,'' AS maker
        ,t.eth_bought AS token_bought_amount_raw
        ,t.tokens_sold AS token_sold_amount_raw
        ,NULL AS amount_usd
        ,'{{weth_address}}' AS token_bought_address --Using WETH for easier joining with USD price table
        ,f.token AS token_sold_address
        ,t.contract_address AS project_contract_address
        ,t.evt_tx_hash AS tx_hash
        ,'' AS trace_address
        ,t.evt_index
    FROM
        {{ source('uniswap_ethereum', 'Exchange_evt_EthPurchase') }} t
    INNER JOIN {{ source('uniswap_ethereum', 'Factory_evt_NewExchange') }} f
        ON f.exchange = t.contract_address
    {% if is_incremental() %}
    WHERE t.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
)
SELECT
    'ethereum' AS blockchain
    ,'uniswap' AS project
    ,'1' AS version
    ,TRY_CAST(date_trunc('DAY', dexs.block_time) AS date) AS block_date
    ,dexs.block_time
    ,erc20a.symbol AS token_bought_symbol
    ,erc20b.symbol AS token_sold_symbol
    ,case
        when lower(erc20a.symbol) > lower(erc20b.symbol) then concat(erc20b.symbol, '-', erc20a.symbol)
        else concat(erc20a.symbol, '-', erc20b.symbol)
    end as token_pair
    ,dexs.token_bought_amount_raw / power(10, erc20a.decimals) AS token_bought_amount
    ,dexs.token_sold_amount_raw / power(10, erc20b.decimals) AS token_sold_amount
    ,CAST(dexs.token_bought_amount_raw AS DECIMAL(38,0)) AS token_bought_amount_raw
    ,CAST(dexs.token_sold_amount_raw AS DECIMAL(38,0)) AS token_sold_amount_raw
    ,coalesce(
        dexs.amount_usd
        ,(dexs.token_bought_amount_raw / power(10, p_bought.decimals)) * p_bought.price
        ,(dexs.token_sold_amount_raw / power(10, p_sold.decimals)) * p_sold.price
    ) AS amount_usd
    ,dexs.token_bought_address
    ,dexs.token_sold_address
    ,coalesce(dexs.taker, tx.from) AS taker -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
    ,dexs.maker
    ,dexs.project_contract_address
    ,dexs.tx_hash
    ,tx.from AS tx_from
    ,tx.to AS tx_to
    ,dexs.trace_address
    ,dexs.evt_index
FROM dexs
INNER JOIN {{ source('ethereum', 'transactions') }} tx
    ON tx.hash = dexs.tx_hash
    {% if not is_incremental() %}
    AND tx.block_time >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND tx.block_time = date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20') }} erc20a
    ON erc20a.contract_address = dexs.token_bought_address
    AND erc20a.blockchain = 'ethereum'
LEFT JOIN {{ ref('tokens_erc20') }} erc20b
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'ethereum'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'ethereum'
    {% if not is_incremental() %}
    AND p_bought.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'ethereum'
    {% if not is_incremental() %}
    AND p_sold.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
;