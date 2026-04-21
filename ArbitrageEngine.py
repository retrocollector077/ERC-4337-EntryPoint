import asyncio 

import logging 

import time 

from typing import Dict, List, Tuple 

from dataclasses import dataclass 

import numpy as np 

 

# Initialize logging 

logging.basicConfig(level=logging.INFO) 

 

@dataclass 

class ArbitrageOpportunity: 

    buy_exchange: str 

    sell_exchange: str 

    buy_price: float 

    sell_price: float 

    profit_margin: float 

    symbol: str 

    timestamp: float 

 

class AdvancedArbitrageEngine: 

    def __init__(self, price_service, exchanges, symbols, api_client, min_profit=0.005): 

        self.price_service = price_service 

        self.exchanges = exchanges 

        self.symbols = symbols 

        self.api_client = api_client 

        self.min_profit = min_profit 

        self.running = True 

        self.active_trades = 0 

        self.trade_lock = asyncio.Lock() 

 

    def detect_arbitrage(self, exchange_prices: Dict[str, Dict[str, float]]) -> List[ArbitrageOpportunity]: 

        opportunities = [] 

        for symbol in self.symbols: 

            prices = {} 

            for ex in self.exchanges: 

                price = exchange_prices.get(ex, {}).get(symbol) 

                if price: 

                    prices[ex] = price 

            if len(prices) < 2: 

                continue 

            sorted_exchanges = sorted(prices.items(), key=lambda x: x[1]) 

            buy_ex, buy_price = sorted_exchanges[0] 

            sell_ex, sell_price = sorted_exchanges[-1] 

            profit_margin = (sell_price - buy_price) / buy_price 

            if profit_margin >= self.min_profit: 

                opportunities.append(ArbitrageOpportunity( 

                    buy_exchange=buy_ex, 

                    sell_exchange=sell_ex, 

                    buy_price=buy_price, 

                    sell_price=sell_price, 

                    profit_margin=profit_margin, 

                    symbol=symbol, 

                    timestamp=time.time() 

                )) 

        return opportunities 

 

    async def execute_trade(self, opportunity: ArbitrageOpportunity): 

        async with self.trade_lock: 

            if self.active_trades >= 3: 

                logging.info("Max concurrent trades reached.") 

                return 

            self.active_trades += 1 

        try: 

            amount = self.calculate_trade_amount(opportunity) 

            await self.api_client.buy(opportunity.buy_exchange, opportunity.symbol, amount) 

            await self.api_client.sell(opportunity.sell_exchange, opportunity.symbol, amount) 

            profit = amount * (opportunity.sell_price - opportunity.buy_price) 

            logging.info(f"Executed trade: {opportunity} Profit: {profit:.2f}") 

        except Exception as e: 

            logging.error(f"Trade failed: {e}") 

        finally: 

            async with self.trade_lock: 

                self.active_trades -= 1 

 

    def calculate_trade_amount(self, opportunity: ArbitrageOpportunity) -> float: 

        # Implement risk management and position sizing 

        base_amount = 0.01 

        return base_amount 

 

    async def run(self): 

        while self.running: 

            # Get latest prices 

            exchange_prices = {} 

            for ex in self.exchanges: 

                exchange_prices[ex] = {} 

                for symbol in self.symbols: 

                    price = self.price_service.get_cached_price(ex, symbol) 

                    if price: 

                        exchange_prices[ex][symbol] = price 

            opportunities = self.detect_arbitrage(exchange_prices) 

            for opp in opportunities: 

                await self.execute_trade(opp) 

            await asyncio.sleep(1) 

 

    def stop(self): 

        self.running = False 

 

# Usage: 

# Instantiate `PriceFeedService`, `APIClient`, then run `run()` 