{{ config(
        alias ='erc721_rolling_day')
}}

        select
            'ethereum' as blockchain,
            day,
            wallet_address,
            token_address,
            tokenId,
            cast(current_timestamp as timestamp) as updated_at,
            row_number() over (partition by token_address, tokenId order by day desc) as recency_index
        from {{ ref('transfers_ethereum_erc721_agg_day') }}
