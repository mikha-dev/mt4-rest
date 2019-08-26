// ------------------------------------------------------------------------------
#define LOG_LEVEL_ERR 1
#define LOG_LEVEL_WARN 2
#define LOG_LEVEL_INFO 3
#define LOG_LEVEL_DBG 4
#include <stdlib.mqh>
#include <stderror.mqh> 

bool sleep_after_operations = false;
int attempts_retry 		= 10; 
double sleep_time 		= 4.0;
double sleep_maximum 	= 25.0;  // in seconds
bool shown_version_info = false;
int ErrorLevel 	= LOG_LEVEL_DBG;
int _OR_err 		= 0;
string XLastError;
int XLastErrorCode;

void XPrint( int log_level, string text, int code ) {
   string prefix, message;
   
   if( log_level > ErrorLevel )
      return;

   switch(log_level) {
      case LOG_LEVEL_ERR:
         prefix = "Error";
         break;
      case LOG_LEVEL_WARN:
         prefix = "Warning";
         break;
      case LOG_LEVEL_INFO:
         prefix = "Info";
         break;
      case LOG_LEVEL_DBG:
         prefix = "Debug";
         break;                  
   }
   
   message = StringConcatenate( prefix, ": ", text );
   
   XLastError = message;   
   XLastErrorCode = code;      
   
   Print(message);
}

int XOrderSend(string symbol, int cmd, double volume, double price,
					  int slippage, double stoploss, double takeprofit,
					  string comment, int magic, datetime expiration = 0, 
					  color arrow_color = CLR_NONE) {

   int digits;
   
	XPrint( LOG_LEVEL_INFO, "Attempted " + XCommandString(cmd) + " " + volume + 
						" lots @" + price + " sl:" + stoploss + " tp:" + takeprofit, 0); 
						
	if (IsStopped()) {
		_OR_err = ERR_COMMON_ERROR; 	
		XPrint( LOG_LEVEL_WARN, "Expert was stopped while processing order. Order was canceled.", _OR_err);
		return(-1);
	}
	
	int cnt = 0;
	while(!IsTradeAllowed() && cnt < attempts_retry) {
		XSleepRandomTime(sleep_time, sleep_maximum); 
		cnt++;
	}
	
	if (!IsTradeAllowed()) 
	{
		_OR_err = ERR_TRADE_CONTEXT_BUSY; 	
		XPrint( LOG_LEVEL_WARN, "No operation possible because Trading not allowed for this Expert, even after retries.", ERR_TRADE_CONTEXT_BUSY );

		return(-1);  
	}

   digits = MarketInfo( symbol, MODE_DIGITS);

   if( price == 0 ) {
      RefreshRates();
      if( cmd == OP_BUY ) {
			price = Ask;      
      }
      if( cmd == OP_SELL ) {
			price = Bid;      
      }      
   }

	if (digits > 0) {
		price = NormalizeDouble(price, digits);
		stoploss = NormalizeDouble(stoploss, digits);
		takeprofit = NormalizeDouble(takeprofit, digits); 
	}
	
	if (stoploss != 0) 
		XEnsureValidStop(symbol, price, stoploss); 

	int err = GetLastError(); // clear the global variable.  
	err = 0; 
	_OR_err = 0; 
	bool exit_loop = false;
	bool limit_to_market = false; 
	double servers_min_stop;
	
	// limit/stop order. 
	int ticket=-1;

	if ((cmd == OP_BUYSTOP) || (cmd == OP_SELLSTOP) || (cmd == OP_BUYLIMIT) || (cmd == OP_SELLLIMIT)) {
		cnt = 0;
		while (!exit_loop) {
			if (IsTradeAllowed()) {
				ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss, takeprofit, comment, magic, expiration, arrow_color);
				err = GetLastError();
				_OR_err = err; 
			} else {
				cnt++;
			} 
			
			switch (err) {
				case ERR_NO_ERROR:
				  if(ticket == -1)
					 exit_loop = false;
					else 
					 exit_loop = true;
					break;
				
				// retryable errors
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY: 
					cnt++; 
					break;
					
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					RefreshRates();
					continue;	// we can apparently retry immediately according to MT docs.
					
				case ERR_INVALID_STOPS:
					servers_min_stop = MarketInfo(symbol, MODE_STOPLEVEL) * XGetPoint(symbol); 
					if (cmd == OP_BUYSTOP) {
						// If we are too close to put in a limit/stop order so go to market.
						if (MathAbs(Ask - price) <= servers_min_stop)	
							limit_to_market = true; 
							
					} 
					else if (cmd == OP_SELLSTOP) 
					{
						// If we are too close to put in a limit/stop order so go to market.
						if (MathAbs(Bid - price) <= servers_min_stop)
							limit_to_market = true; 
					}
					exit_loop = true; 
					break; 
					
				default:
					// an apparently serious error.
					exit_loop = true;
					break; 
					
			}  // end switch 

			if (cnt > attempts_retry) 
				exit_loop = true; 
			 	
			if (exit_loop) {
				if (err != ERR_NO_ERROR) {
					XPrint( LOG_LEVEL_ERR, "Non-retryable error - " + XErrorDescription(err), err); 
				}
				if (cnt > attempts_retry) {
					XPrint( LOG_LEVEL_INFO, "Retry attempts maxed at " + attempts_retry, 0); 
				}
			}
			 
			if (!exit_loop) {
				XPrint( LOG_LEVEL_DBG, "Retryable error (" + cnt + "/" + attempts_retry + 
									"): " + XErrorDescription(err), err); 
				XSleepRandomTime(sleep_time, sleep_maximum); 
				RefreshRates(); 
			}
		}
		 
		// We have now exited from loop. 
		if (err == ERR_NO_ERROR) {
			XPrint( LOG_LEVEL_INFO, "apparently successful order placed.", 0);
			return(ticket); // SUCCESS! 
		} 
		if (!limit_to_market) {
			XPrint( LOG_LEVEL_ERR, "failed to execute stop or limit order after " + cnt + " retries", err);
			XPrint( LOG_LEVEL_INFO, "failed trade: " + XCommandString(cmd) + " " + symbol + 
								"@" + price + " tp@" + takeprofit + " sl@" + stoploss, 0); 
			XPrint( LOG_LEVEL_INFO, "last error: " + XErrorDescription(err), 0); 
			return(-1); 
		}
	}  // end	  
  
	if (limit_to_market) {
		XPrint( LOG_LEVEL_DBG, "going from limit order to market order because market is too close.", 0 );
		RefreshRates();
		if ((cmd == OP_BUYSTOP) || (cmd == OP_BUYLIMIT)) {
			cmd = OP_BUY;
			price = Ask;
		} 
		else if ((cmd == OP_SELLSTOP) || (cmd == OP_SELLLIMIT)) 
		{
			cmd = OP_SELL;
			price = Bid;
		}	
	}
	
	// we now have a market order.
	err = GetLastError(); // so we clear the global variable.  
	err = 0; 
	_OR_err = 0; 
	ticket = -1;

	if ((cmd == OP_BUY) || (cmd == OP_SELL)) {
		cnt = 0;
		while (!exit_loop) {
			if (IsTradeAllowed()) {
				ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss, takeprofit, comment, magic, expiration, arrow_color);
				err = GetLastError();
				_OR_err = err; 
			} else {
				cnt++;
			} 
			switch (err) {
				case ERR_NO_ERROR:
		      if(ticket == -1)
				  exit_loop = false;
				else
				  exit_loop = true;
					break;
					
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY: 
					cnt++; // a retryable error
					break;
					
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					RefreshRates();
					continue; // we can apparently retry immediately according to MT docs.
					
				default:
					// an apparently serious, unretryable error.
					exit_loop = true;
					break; 
					
			}  // end switch 

			if (cnt > attempts_retry) 
			 	exit_loop = true; 
			 	
			if (!exit_loop) {
				XPrint( LOG_LEVEL_DBG, "retryable error (" + cnt + "/" + 
									attempts_retry + "): " + XErrorDescription(err), err); 
				XSleepRandomTime(sleep_time,sleep_maximum); 
				RefreshRates(); 
			}
			
			if (exit_loop) {
				if (err != ERR_NO_ERROR) {
					XPrint( LOG_LEVEL_ERR, "non-retryable error: " + XErrorDescription(err), err); 
				}
				if (cnt > attempts_retry) {
					XPrint( LOG_LEVEL_INFO, "retry attempts maxed at " + attempts_retry, 0); 
				}
			}
		}
		
		// we have now exited from loop. 
		if (err == ERR_NO_ERROR) {
			XPrint( LOG_LEVEL_INFO, "apparently successful order placed, details follow.", 0);
//			OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES); 
//			OrderPrint(); 
			return(ticket); // SUCCESS! 
		} 
		XPrint( LOG_LEVEL_ERR, "Failed open " + symbol + " " + XCommandString(cmd) + "@" + volume + ", " + cnt + " retries, " + XErrorDescription(err), err);
		XPrint( LOG_LEVEL_INFO, "failed trade: " + XCommandString(cmd) + " " + symbol + "@" + price + " tp@" + takeprofit + " sl@" + stoploss, 0); 
		//XPrint( LOG_LEVEL_INFO, "last error: " + XErrorDescription(err)); 
		return(-1); 
	}
	
	return 0;
}

int XOrderSend2Step(string symbol, int cmd, double volume, double price,
					  int slippage, double stoploss, double takeprofit,
					  string comment, int magic, datetime expiration = 0, 
					  color arrow_color = CLR_NONE) {

   int mkt_ticket = XOrderSend(symbol,cmd,volume,price,slippage,0,0,comment,magic,expiration,arrow_color);
   if (mkt_ticket > 0 && (stoploss!=0 || takeprofit!=0)) {   
      if( OrderSelect(mkt_ticket,SELECT_BY_TICKET) ) {
         XSleepRandomTime(sleep_time,sleep_maximum);
         XOrderModify(mkt_ticket,OrderOpenPrice(),stoploss,takeprofit,0,arrow_color);
      }
   }
   return (mkt_ticket);
}

bool XOrderModify(int ticket, double price, double stoploss, 
						 double takeprofit, datetime expiration, 
						 color arrow_color = CLR_NONE) {

	XPrint( LOG_LEVEL_INFO, " attempted modify of #" + ticket + " price:" + price + " sl:" + stoploss + " tp:" + takeprofit, 0); 

	if (IsStopped()) {
		XPrint( LOG_LEVEL_WARN, "Expert was stopped while processing order. Order was canceled.", 0);
		return(false);
	}
	
	int cnt = 0;
	while(!IsTradeAllowed() && cnt < attempts_retry) {
		XSleepRandomTime(sleep_time,sleep_maximum); 
		cnt++;
	}
	if (!IsTradeAllowed()) {
		_OR_err = ERR_TRADE_CONTEXT_BUSY; 	
		XPrint( LOG_LEVEL_WARN, "No operation possible because Trading not allowed for this Expert, even after retries.", ERR_TRADE_CONTEXT_BUSY);
		return(false);  
	}

	int err = GetLastError(); // so we clear the global variable.  
	err = 0; 
	_OR_err = 0; 
	bool exit_loop = false;
	cnt = 0;
	bool result = false;
	
	while (!exit_loop) {
		if (IsTradeAllowed()) {
			result = OrderModify(ticket, price, stoploss, takeprofit, expiration, arrow_color);
			err = GetLastError();
			_OR_err = err; 
		} 
		else 
			cnt++;

		if (result == true) 
			exit_loop = true;

		switch (err) {
			case ERR_NO_ERROR:
			  if(result == true)
				  exit_loop = true;
				else
				  exit_loop = false;
				break;
				
			case ERR_NO_RESULT:
				// modification without changing a parameter. 
				// if you get this then you may want to change the code.
				exit_loop = true;
				break;
				
			case ERR_SERVER_BUSY:
			case ERR_NO_CONNECTION:
			case ERR_INVALID_PRICE:
			case ERR_OFF_QUOTES:
			case ERR_BROKER_BUSY:
			case ERR_TRADE_CONTEXT_BUSY: 
			case ERR_TRADE_TIMEOUT:		// for modify this is a retryable error, I hope. 
				cnt++; 	// a retryable error
				break;
				
			case ERR_PRICE_CHANGED:
			case ERR_REQUOTE:
				RefreshRates();
				continue; 	// we can apparently retry immediately according to MT docs.
				
			default:
				// an apparently serious, unretryable error.
				exit_loop = true;
				break; 
				
		}  // end switch 

		if (cnt > attempts_retry) 
			exit_loop = true; 
			
		if (!exit_loop) 
		{
			XPrint( LOG_LEVEL_DBG, "retryable error (" + cnt + "/" + attempts_retry + "): "  +  XErrorDescription(err), err); 
			XSleepRandomTime(sleep_time,sleep_maximum); 
			RefreshRates(); 
		}
		
		if (exit_loop) {
			if ((err != ERR_NO_ERROR) && (err != ERR_NO_RESULT)) 
				XPrint( LOG_LEVEL_ERR, "non-retryable error: "  + XErrorDescription(err), err); 

			if (cnt > attempts_retry) 
				XPrint( LOG_LEVEL_INFO, "retry attempts maxed at " + attempts_retry, 0); 
		}
	}  
	
	// we have now exited from loop. 
	if ((result == true) || (err == ERR_NO_ERROR)) 	{
		XPrint( LOG_LEVEL_INFO, "apparently successful modification order.", 0);
		return(true); // SUCCESS! 
	} 
	
	if (err == ERR_NO_RESULT) {
		XPrint( LOG_LEVEL_WARN, "Server reported modify order did not actually change parameters.", 0);
		return(true);
	}
	
	XPrint( LOG_LEVEL_ERR, "Failed modify " + XCommandString(OrderType()) + ", " + cnt + " retries, " + XErrorDescription(err), err);
	XPrint( LOG_LEVEL_INFO, "failed modification: "  + ticket + " @" + price + " tp@" + takeprofit + " sl@" + stoploss, 0); 
//	XPrint( LOG_LEVEL_INFO, "last error: " + XErrorDescription(err)); 
	
	return(false);  
}

bool XOrderClose(int ticket, double lots, double price, int slippage, color arrow_color = CLR_NONE) {
	int nOrderType;
	string strSymbol;
	
	XPrint( LOG_LEVEL_INFO, " attempted close of #" + ticket + " price:" + price + " lots:" + lots + " slippage:" + slippage, 0); 

	// collect details of order so that we can use GetMarketInfo later if needed
	if (!OrderSelect(ticket,SELECT_BY_TICKET)) {
		_OR_err = GetLastError();		
		XPrint( LOG_LEVEL_ERR, XErrorDescription(_OR_err), _OR_err);
		return(false);
	} else {
		nOrderType = OrderType();
		strSymbol = OrderSymbol();
	}

	if (nOrderType != OP_BUY && nOrderType != OP_SELL)	{
		_OR_err = ERR_INVALID_TICKET;
		XPrint( LOG_LEVEL_WARN, "trying to close ticket #" + ticket + ", which is " + XCommandString(nOrderType) + ", not BUY or SELL", 0);
		return(false);
	}

	if (IsStopped()) {
		XPrint( LOG_LEVEL_WARN, "Expert was stopped while processing order. Order processing was canceled.", 0);
		return(false);
	}

	
	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.  
	err = 0; 
	_OR_err = 0; 
	bool exit_loop = false;
	cnt = 0;
	bool result = false;
	
	if( lots == 0)
	  lots = OrderLots();
	
	for(int j = 0; j < 10; j++) {
	
	  if(price != 0)
	    break;
	    
	  RefreshRates();
	  if (nOrderType == OP_BUY)  
		  price = NormalizeDouble(MarketInfo(strSymbol, MODE_BID), MarketInfo(strSymbol, MODE_DIGITS));
	  if (nOrderType == OP_SELL) 
		  price = NormalizeDouble(MarketInfo(strSymbol, MODE_ASK), MarketInfo(strSymbol, MODE_DIGITS));
	}
	
	while (!exit_loop) 
	{
		if (IsTradeAllowed()) 
		{
			result = OrderClose(ticket, lots, price, slippage, arrow_color);
			err = GetLastError();
			_OR_err = err; 
		} 
		else 
			cnt++;

		if (result == true) 
			exit_loop = true;

		switch (err) {
			case ERR_NO_ERROR:
			  if(result == true)
				  exit_loop = true;
				else
				  exit_loop = false;
				break;
				
			case ERR_SERVER_BUSY:
			case ERR_NO_CONNECTION:
			case ERR_INVALID_PRICE:
			case ERR_OFF_QUOTES:
			case ERR_BROKER_BUSY:
			case ERR_TRADE_CONTEXT_BUSY: 
			case ERR_TRADE_TIMEOUT:		// for modify this is a retryable error, I hope. 
				cnt++; 	// a retryable error
				break;
				
			case ERR_PRICE_CHANGED:
			case ERR_REQUOTE:
				continue; 	// we can apparently retry immediately according to MT docs.
				
			default:
				// an apparently serious, unretryable error.
				exit_loop = true;
				break; 
				
		}  // end switch 

		if (cnt > attempts_retry) 
			exit_loop = true; 
			
		if (!exit_loop) 
		{
			XPrint( LOG_LEVEL_DBG, "retryable error (" + cnt + "/" + attempts_retry + "): "  +  XErrorDescription(err), err); 
			XSleepRandomTime(sleep_time,sleep_maximum); 
			
			// Added by Paul Hampton-Smith to ensure that price is updated for each retry
			if (nOrderType == OP_BUY)  
				price = NormalizeDouble(MarketInfo(strSymbol, MODE_BID), MarketInfo(strSymbol, MODE_DIGITS));
			if (nOrderType == OP_SELL) 
				price = NormalizeDouble(MarketInfo(strSymbol, MODE_ASK), MarketInfo(strSymbol, MODE_DIGITS));
		}
		
		if (exit_loop) 
		{
			if ((err != ERR_NO_ERROR) && (err != ERR_NO_RESULT))  {
				XPrint( LOG_LEVEL_ERR, "non-retryable error: " + XErrorDescription(err), err); 
				return false;
			}

			if (cnt > attempts_retry) 
				XPrint( LOG_LEVEL_INFO, "retry attempts maxed at " + attempts_retry, 0); 
		}
	}
	
	// we have now exited from loop. 
	if ((result == true) || (err == ERR_NO_ERROR)) {
		XPrint( LOG_LEVEL_INFO, "apparently successful close order.", 0);
		return(true); // SUCCESS! 
	} 
	
	XPrint( LOG_LEVEL_ERR, "Failed close " + XCommandString(OrderType()) + ", " + cnt + " retries, " + XErrorDescription(err), err);
	XPrint( LOG_LEVEL_INFO, "failed close: Ticket #" + ticket + ", Price: " + price + ", Slippage: " + slippage, 0); 
	//XPrint( LOG_LEVEL_INFO, "last error: " + XErrorDescription(err)); 
	
	return(false);  
}

string XCommandString(int cmd) {
	if (cmd == OP_BUY) 
		return("BUY");

	if (cmd == OP_SELL) 
		return("SELL");

	if (cmd == OP_BUYSTOP) 
		return("BUY STOP");

	if (cmd == OP_SELLSTOP) 
		return("SELL STOP");

	if (cmd == OP_BUYLIMIT) 
		return("BUY LIMIT");

	if (cmd == OP_SELLLIMIT) 
		return("SELL LIMIT");

	return("(" + cmd + ")"); 
}

void XEnsureValidStop(string symbol, double price, double& sl) {
	// Return if no S/L
	if (sl == 0) 
		return;
	
	double servers_min_stop = MarketInfo(symbol, MODE_STOPLEVEL) * XGetPoint(symbol); 
	
	if (MathAbs(price - sl) <= servers_min_stop) {
		// we have to adjust the stop.
		if (price > sl)
			sl = price - servers_min_stop;	// we are long
			
		else if (price < sl)
			sl = price + servers_min_stop;	// we are short			
		else
			XPrint( LOG_LEVEL_WARN, "Passed Stoploss which equal to price", 0); 
			
		sl = NormalizeDouble(sl, MarketInfo(symbol, MODE_DIGITS)); 
	}
}

double XGetPoint( string symbol ) {
   double point;
   
   point = MarketInfo( symbol, MODE_POINT );
   double digits = NormalizeDouble( MarketInfo( symbol, MODE_DIGITS ),0 );
   
   if( digits == 3 || digits == 5 ) {
      return(point*10.0);
   }
   
   return(point);
}


void XSleepRandomTime(double mean_time, double max_time) {

  if(sleep_after_operations == false)
    return;
    
	if (IsTesting()) 
		return; 	// return immediately if backtesting.

	double tenths = MathCeil(mean_time / 0.1);
	if (tenths <= 0) 
		return; 
	 
	int maxtenths = MathRound(max_time/0.1); 
	double p = 1.0 - 1.0 / tenths; 
	  
	Sleep(100); 	// one tenth of a second PREVIOUS VERSIONS WERE STUPID HERE. 
	
	for(int i=0; i < maxtenths; i++) {
		if (MathRand() > p*32768) 
			break; 
			
		// MathRand() returns in 0..32767
		Sleep(100); 
	}
	
	Print("Slept");
}  
 
string XErrorDescription(int err) {
   return(ErrorDescription(err)); 
}

double XGetPips() {
   double bid, ask, point, digits, pips;
     
   bid = MarketInfo( OrderSymbol(), MODE_BID );
   ask = MarketInfo( OrderSymbol(), MODE_ASK );
   point = MarketInfo( OrderSymbol(), MODE_POINT );
   digits =  MarketInfo(OrderSymbol(),MODE_DIGITS);
   if(digits == 3 || digits ==5) {
    point = point*10;
   }   
   
  if(OrderType() == OP_BUY) {
    pips = (bid - OrderOpenPrice())/point;
  }
  
  if(OrderType() == OP_SELL) {
    pips = (OrderOpenPrice() - ask)/point;
  }  
  
  return pips;
}

double XGetSLPips() {
   double point, digits, pips;
     
   point = MarketInfo( OrderSymbol(), MODE_POINT );
   digits =  MarketInfo(OrderSymbol(),MODE_DIGITS);
   if(digits == 3 || digits ==5) {
    point = point*10;
   }   
   
  if(OrderType() == OP_SELL) {
    pips = (OrderOpenPrice() - OrderStopLoss())/point;
  }
  
  if(OrderType() == OP_BUY) {
    pips = (OrderStopLoss() - OrderOpenPrice())/point;
  }  
  
  return pips;
}

int LotPrecision(){
   double lotstep = MarketInfo(Symbol(),MODE_LOTSTEP);
   if(lotstep==1)     return(0);
   if(lotstep==0.1)   return(1);
   if(lotstep==0.01)  return(2);
   if(lotstep==0.001) return(3);
   
   return 4;
}

int CountOrders( string symbol ) {
   int cnt = 0;
   int ticketAlong = 0;
   
   for( int i = 0; i < OrdersTotal(); i++ ) {
      if( false == OrderSelect( i, SELECT_BY_POS, MODE_TRADES ) )
         continue;
      
      if( OrderCloseTime() != 0 )
         continue;
         
      if( OrderSymbol() == symbol ) {
         ticketAlong = OrderTicket();
         cnt++;
      }
   }
   
   if(cnt == 1)
    OrderSelect( ticketAlong, SELECT_BY_TICKET );
    
   return(cnt);
}

double AccountPercentStopPips(double _balance, string symbol, double percent, double lots, bool IncludeSpreadInSL)
{
    double moneyrisk    = _balance * percent / 100;
    double spread       = MarketInfo(symbol, MODE_SPREAD);
    double point        = MarketInfo(symbol, MODE_POINT);
    double ticksize     = MarketInfo(symbol, MODE_TICKSIZE);
    double tickvalue    = MarketInfo(symbol, MODE_TICKVALUE);
    double tickvaluefix = tickvalue * point / ticksize; // A fix for an extremely rare occasion when a change in ticksize leads to a change in tickvalue
    
    double stoploss;
    
    if(IncludeSpreadInSL)
      stoploss = moneyrisk / (lots * tickvaluefix ) - spread;
    else
      stoploss = moneyrisk / (lots * tickvaluefix );
    
    if (stoploss < MarketInfo(symbol, MODE_STOPLEVEL))
        stoploss = MarketInfo(symbol, MODE_STOPLEVEL); // This may rise the risk over the requested
        
    stoploss = NormalizeDouble(stoploss, 0);
    
    return (stoploss);
}