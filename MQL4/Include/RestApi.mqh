#property version   "1.00"
int Slippage = 30;
int Magic = 11111;
#include <Json.mqh>
#include <Strings/String.mqh>
#include <XTrade.mqh>

#import "mt4-rest.dll"
   int Init( const uchar &url[], int port, int command_wait_timeout);
   int GetCommand(uchar &data[]);
   int SetCommandResponse(const uchar &command[], const uchar &response[]);
   void Deinit();
#import

class CRestApi
  {

public:
                     CRestApi(void);
                    ~CRestApi(void);
                    
   //---
   bool              Init(string _host, int _port, int commandWaitTimeout);
   void              SetIPsAllowed(string IPs) {
    ips_allowed = IPs;
   };
   void              Deinit(void);
   void              Processing(void);

private:
  void               doOpen(string symbol, string dir, string risk, string sl, string tp, bool is_virtual_sl, string ts);
  void               doClose(string symbol, string command);
  void               doCloseAll(string symbol, string dir="");
  string             doModify(int id);
  string             notImpemented(string command);
  string             notAllowed(string host);
  string             processAlert( string message );
  
  double             parseSL( string symbol, int cmd, double price, string sl_string );
  double             parseTP( string symbol, int cmd, double price, string tp_string );
  double             calcLots(string symbol, string risk_string, double sl);
private:
   bool debug;
   string ips_allowed;
};

CRestApi::CRestApi(void) {
   debug = true;
}
//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CRestApi::~CRestApi(void) {
}

bool CRestApi::Init(string _host, int _port, int _commandWaitTimeout) {
   uchar __host[];
   StringToCharArray(_host, __host);
   
   Init(__host,_port, _commandWaitTimeout);
   
   if(debug) Print("started");
   
   ChartRedraw();
   return(true);   
}

void CRestApi::Deinit(void) {
   Deinit();
}

void CRestApi::Processing(void) {
  
  uchar _command[8048];
  uchar _response[];
  string command = {0}, response = {0};
  
   int r = 0;
   r = GetCommand( _command );
   
   if(r == 1) {
      command = CharArrayToString( _command );
      Print("request: " + command);
      
      CJAVal jRequest;
      
      jRequest.Deserialize( command );
      
      string action = jRequest["command"].ToStr();
      
      if(action == "inited") {
         Print("Listening on: " + jRequest["options"].ToStr());
         Comment("Open " + jRequest["options"].ToStr() + " for docs");
         
         return;
      }      
      
      if(action == "failed") {
         Print("Failed to start, error: " + jRequest["options"].ToStr());
         Comment("Failed to start server: " + jRequest["options"].ToStr());
         
         return;
      }            
      
      string host = jRequest["host"].ToStr();      
      Print("Request host: " + host);
      
      if(StringFind( ips_allowed, host) == -1 ) {
        Print("Host is not allowed. IP: " + host);
        
        response = notAllowed(host);
        
        StringToCharArray(response,_response);
        SetCommandResponse( _command, _response );        
        
        return;
      }      
      
      CJAVal path = jRequest["path"];
      
      /* CJAVal query = jRequest["query"];
      
      CJAVal* test = query.HasKey("test", jtSTR);
      if(test)
        Print(test.ToStr());
      else
        Print("query test - 0");
        */
        
      if(path[0].ToStr() == "alert") {
        string body = jRequest["body"].ToStr();
        
        response = processAlert(body);
      }
      
      if(StringLen(response) < 1) {
         response = notImpemented( jRequest.ToStr() );
      }       

      StringToCharArray(response,_response);
      SetCommandResponse( _command, _response );
   }
}

string CRestApi::processAlert( string message ) {
  CJAVal ret;
  
  if(debug)
    Print(message);
  
  StringReplace( message, " ", "" );
  StringToLower( message );
  StringReplace( message, ":", "\":\"" );
  if(StringFind( message, "\r\n") != -1)
    StringReplace( message, "\r\n", "\",\"" );
  else  
    StringReplace( message, "\n", "\",\"" );
  message = "{\"" + message + "\"}";
  
  if(debug)
    Print(message);
    
  CJAVal command;
  string cClose, cOpen, cSymbol, cRisk, cSL, cTP, cTS;
  bool cEnabled;
  
  command.Deserialize( message );
  cClose = command["close"].ToStr();
  cOpen = command["go"].ToStr();
  cSymbol = command["symbol"].ToStr();
  StringToUpper(cSymbol);
  
  if(StringLen(cClose) > 1) {    
    doClose(cSymbol, cClose);
  }
  
  if(StringLen(cOpen) > 1) {
    cRisk = command["risk"].ToStr();
    cSL = command["sl"].ToStr();
    cTP = command["tp"].ToStr();
    cEnabled = command["enabled"].ToStr() == "yes";
    cTS = command["ts"].ToStr();
    doOpen(cSymbol, cOpen, cRisk, cSL, cTP, cEnabled, cTS);
  }  
      
  return message;
}

void CRestApi::doClose(string symbol, string command) {
  bool is_rm = false;
  double percent, lots;
  
  if( CountOrders(symbol) == 1 ) {
    if(StringLen(command) <= 4) {
      StringReplace(command, "%", "");
      percent = StringToDouble( command );
      
      lots = OrderLots()*percent/100.0;
      
      closeOrder( lots );
      
      return;
    }
  }
  
  for(int i = 0; i < OrdersTotal(); i++) {
    if ( OrderSelect( i, SELECT_BY_POS, MODE_TRADES) == false ) {
       Print("Access to open orders failed with error(" + GetLastError() + ")");
       break;
    }
  
    if(OrderSymbol() == symbol) {
      is_rm = false;
      double percent = 100;
      
      if(StringFind( command, "-" + OrderTicket() ) != -1 ) {
        continue;
      }      

      if(StringFind( command, "all") != -1) {
        is_rm = true;
      }            
      
      if(StringFind( command, OrderTicket() ) != -1 ) {
        int idx = StringFind( command, OrderTicket());
        
        idx = idx + StringLen("" + OrderTicket());
        
        if(StringGetChar( command, idx ) == '/' ) {
          string p = StringSubstr( command, idx + 1,2);
          
          Print("going to close " + p + "% of " + OrderTicket());
        
          percent = StringToDouble( p );
        }
        is_rm = true;
      }
            
      if(!is_rm && ( StringFind( command, "short") != -1 && OrderType() == OP_SELL ) ) {
        is_rm = true;
      }
      
      if(!is_rm && ( StringFind( command, "long") != -1 && OrderType() == OP_BUY ) ) {
        is_rm = true;
      }      

      if(is_rm) {        
        if( closeOrder(OrderLots()*percent/100.0) )
          i--;
      }
    }
  }
  
  return;
}

bool closeOrder( double lots = 0 ) {
  string symbol;
  double price;

  symbol = OrderSymbol();
  
  if(lots == 0 )
    lots = OrderLots();

  RefreshRates();
  if( OrderType() == OP_BUY || OrderType() == OP_SELL ) {
    if( OrderType() == OP_BUY )
       price = NormalizeDouble( MarketInfo( symbol, MODE_BID ), MarketInfo( symbol, MODE_DIGITS ) );
    else
       price = NormalizeDouble( MarketInfo( symbol, MODE_ASK ), MarketInfo( symbol, MODE_DIGITS ) );
  
    return( XOrderClose( OrderTicket(), lots, price, Slippage ) );
  } else {
    OrderDelete( OrderTicket() );
    return(true);
  }

}

string CRestApi::doModify(int id) {
  return "done";
}

void CRestApi::doOpen(string symbol, string dir, string risk, string sl_string, string tp_string, bool is_virtual_sl, string ts) {
  double price, sl, lots, tp;
  int cmd = OP_BUY;
  ResetLastError();  
        
  price = SymbolInfoDouble(symbol,SYMBOL_ASK);                                        
  if(dir == "short") {
    price = SymbolInfoDouble(symbol,SYMBOL_BID);
    cmd = OP_SELL;
  }
  
  sl = parseSL( symbol, cmd, price, sl_string );  
  tp = parseTP( symbol, cmd, price, tp_string );  
  
  lots = calcLots(symbol, risk, MathAbs(price - sl));
  
  XOrderSend( symbol, cmd, lots, price, Slippage, sl, tp, "", Magic );
}

double CRestApi::calcLots(string symbol, string risk_string, double sl) {
  double risk_percent, risk_money = 0;
  
  if(StringFind( risk_string, "lots") != -1 || StringFind( risk_string, "lot") != -1) {
    StringReplace( risk_string, "lot", "" );
    StringReplace( risk_string, "lots", "" );
    StringReplace( risk_string, " ", "" );
    
    return StringToDouble( risk_string );
  }
  
  if(StringFind( risk_string, "$" )!= -1) {
    StringReplace( risk_string, "$", "" );
    
    risk_money = StringToDouble( risk_string );
  }
  
  StringReplace( risk_string, "%", "" );
  
  risk_percent = StringToDouble( risk_string );
  
  double MMBalance, MMRiskMoney;
  double MMMaxLot=MarketInfo( symbol, MODE_MAXLOT );
  double MMMinLot=MarketInfo( symbol, MODE_MINLOT );
  double MMLotStep= MarketInfo( symbol, MODE_LOTSTEP ); 
  double MMTickValue = MarketInfo( symbol, MODE_TICKVALUE);
  double MMTickSize = MarketInfo( symbol, MODE_TICKSIZE);
  
  int lotdigits=0;
  do
  {
    lotdigits++;
    MMLotStep*=10;
  }while(MMLotStep<1);
    
  if(risk_money != 0) {
    MMRiskMoney = risk_money;
  } else {
    MMBalance = MathMin(AccountBalance(), AccountEquity());  
    MMRiskMoney = MMBalance*risk_percent /100.0;
  }
  
  double lot = MMRiskMoney / ( sl * ( MMTickValue / MMTickSize ) );
  lot = NormalizeDouble( MathFloor(lot*MathPow(10,lotdigits))/MathPow(10,lotdigits), lotdigits );
  if( lot > MMMaxLot ){ lot=MMMaxLot; }
  if( lot < MMMinLot ){ lot=MMMinLot; }
  
  return NormalizeDouble( lot, lotdigits );  
}

double CRestApi::parseSL( string symbol, int cmd, double price, string sl_string ) {
  double sl_pips, sl;
  
  if(StringFind( sl_string, "pips") != -1 || StringFind( sl_string, "pip") != -1) {
    StringReplace( sl_string, "pips", "" );
    StringReplace( sl_string, "pip", "" );
    StringReplace( sl_string, " ", "" );
    
    sl_pips = StringToDouble( sl_string );
    
    if(cmd == OP_BUY) {
      sl = price - sl_pips*XGetPoint(symbol);
    } else
      sl = price + sl_pips*XGetPoint(symbol);
      
    return sl;
  }
  
  return StringToDouble( sl_string );
}

double CRestApi::parseTP( string symbol, int cmd, double price, string tp_string ) {
  double tp_pips, tp;
  
  if(StringFind( tp_string, "pips") != -1 || StringFind( tp_string, "pip") != -1) {
    StringReplace( tp_string, "pips", "" );
    StringReplace( tp_string, "pip", "" );
    StringReplace( tp_string, " ", "" );
    
    tp_pips = StringToDouble( tp_string );
    
    if(cmd == OP_BUY) {
      tp = price + tp_pips*XGetPoint(symbol);
    } else
      tp = price - tp_pips*XGetPoint(symbol);
      
    return tp;
  }
  
  return StringToDouble( tp_string );
}

string CRestApi::notImpemented(string command) {
   CJAVal info;
   
   info["error"] = "Not implemented";
   info["command"] = command;
   
   string t = info.Serialize();
   
   if(debug) Print(t);
   
   return t;
}

string CRestApi::notAllowed(string host) {
   CJAVal info;
   
   info["error"] = "Host is not allowed. IP: " + host;
   
   string t = info.Serialize();
   
   if(debug) Print(t);
   
   return t;
}

