/++
 + A simple way to run your D scripts/applications on a webserver
 + ---
 + import std.stdio;
 + import reserved.reserved;
 +
 + @ReservedResponse
 + void response(Request req, Output output)
 + {
 +   // A really useful application.
 +   output ~= "Hello ";
 +   if ("name" in req.get) output ~= req.get["name"];
 +   else output ~= "World";
 + }
 +
 + mixin Reserved!"awesome_d_webservice";
 + ---
 +/
 
module reserved;

private import std.datetime      : DateTime; // For cookies
private import std.string        : toLower, format, empty;
private import core.sync.mutex   : Mutex;
private import std.exception;
private import std.socket;

__gshared Mutex lock;

/// UDA. Annotate a function ```bool your_function()``` or ```bool your_function(string[] args)``` to execute it once before the first request.
public enum ReservedInit;

/// UDA. Annotate a function ```void response(Request req, Output output)``` that will be called for each request.     
public enum ReservedResponse; 

/** Remember to mixin this on your main file.
 * Params:
 *      serviceName = A UNIX socket will be created inside /tmp/run/serviceName dir. 
 */
template Reserved(string serviceName)
{
   // This will catch term signals
   extern(C)
   void exit_gracefully(int value)
   {
      import core.stdc.stdlib : exit;
      lock.lock();
      exit(0);
   }

   int main(string[] args)
   {
      import core.sys.posix.unistd;
      import core.sys.posix.signal;
      import core.sync.mutex;
      import std.traits : hasUDA, ReturnType;
      import std.file : mkdirRecurse, write, readText, exists, remove;
      
      ulong listenerId = 0;

      // Command line parsing
      {
         import std.getopt;
      
         auto parsedArgs = getopt
         (
            args,
            "listenerId|i", "Id used by listener, default = 0",  &listenerId
         );
   
         if (parsedArgs.helpWanted)
         {
            defaultGetoptPrinter("Reserved listener for " ~ serviceName, parsedArgs.options);
            return 0;
         }
      }

      synchronized { lock = new Mutex(); }

      // Catching signal
      sigset(SIGINT, &exit_gracefully);
      sigset(SIGTERM, &exit_gracefully);

      // Search for basic functions
      auto getReservedFunction(alias T)()
      {
         foreach(name;  __traits(allMembers,  __traits(parent, main)))
            static if (hasUDA!(__traits(getMember, __traits(parent, main), name), T))
               return &__traits(getMember, __traits(parent, main), name);
      }

      // Check if init function is good for us.
      static if (!is(ReturnType!(getReservedFunction!ReservedInit) : void))
      {
         auto init = getReservedFunction!ReservedInit;
         static if (!is(ReturnType!init == bool)) static assert(0, "@ReservedInit musts return a bool");
         static if (__traits(compiles, init(args))) enum callInitWithParams = true;
         else enum callInitWithParams = false;
      }
      else // Init function is optional
      {
         auto init = function() { return true; };
         enum callInitWithParams = false;
      } 

      // Check if handler is good for us too.
      static if (!is(ReturnType!(getReservedFunction!ReservedResponse) : void)) 
         auto handler = getReservedFunction!ReservedResponse;
      else static assert(0, "You must define a @ReservedResponse function");

      static if (!__traits(compiles, handler(Request.init, Output.init))) static assert(0, "@ReservedResponse musts accept Request and Output as params");
      else {

         // Call init function
         bool initResult;

         static if (callInitWithParams) initResult = init(args);
         else initResult = init();
         
         if (!initResult)
         {
            reservedLog("Init failed, exit.");
            return -1;
         }

         // Our socket
         import std.format : format;
         immutable basePath = "/tmp/run/" ~ serviceName;
         immutable socketFile = format("%s/listener.%s.sock", basePath, listenerId);
         
         // Create dir if not exists
         mkdirRecurse(basePath);

         // Is anyone else using our socket?
         {
            import std.process : executeShell;
            import core.thread : Thread;
            import core.time : dur;

            // Kill it gently
            executeShell("touch " ~ socketFile ~ "; fuser -k -SIGTERM " ~ socketFile);
            Thread.sleep(dur!"msecs"(200));

            // Kill it!
            executeShell("touch " ~ socketFile ~ "; fuser -k -SIGKILL " ~ socketFile);
         }

         if (exists(socketFile)) 
            remove(socketFile);

       __reservedImpl!serviceName(handler, socketFile);
      }
      
      return 0;
   }	
}

void __reservedImpl(string serviceName, H)(H handler, string socketFile)
{
   import std.range : chunks, array;
   import std.conv : to;
   
   // Let's listen using a brand new socket
   UnixAddress address = new UnixAddress(socketFile);
   
   Socket receiver;
   Socket listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
   listener.blocking = true;
   listener.bind(address);
   listener.listen(3);

   reservedLog("Ok, ready. Socket:", socketFile);

   // Buffer we use to read request from server
   char[] buffer;
   buffer.length = 4096;
   
   char[] requestData;
   requestData.reserve = 4096*10;

   while(true)
   {
      requestData.length = 0;

      string[string] headers;
      bool headersCompleted = false;
      bool requestCompleted = false;

      // We accept request from webserver            
      receiver = listener.accept();

      // We use lock to prevent shutting down during operation
      lock.lock();

            
      while(!requestCompleted)
      {
         import std.ascii : isDigit;

         // Read some data from server
         auto received = receiver.receive(buffer);
         
         // Something goes wrong?
         if (received < 0)
         {
            requestData.length = 0;
            break;
         }

         // Append data
         requestData ~= buffer[0..received];

         if (!headersCompleted)
         {
            // Check if request is complete
            foreach(idx,c; requestData)
            {
               if (!(c.isDigit || c == ':')) 
                  break;
               
               if (c == ':')
               {
                  size_t headersSize = requestData[0..idx].to!size_t;
                  if (requestData.length >= headersSize + idx)
                  {
                     headersCompleted = true;

                     // Parse headers
                     import std.algorithm : splitter;
                     foreach(pair; requestData[idx+1..idx+1+headersSize].to!string.splitter('\0').chunks(2))
                     {
                        auto p = pair.array;
                        
                        if (p[0].empty) 
                           continue;

                        headers[p[0]] = p[1];
                     }

                     requestData = requestData[idx+1+headersSize+1..$];
                     break;
                  }
               }
            }
         }
         
         if (headersCompleted && requestData.length >= headers["CONTENT_LENGTH"].to!size_t)
            requestCompleted = true;
      }

      if (!requestCompleted)
      {
         // TODO: Bad request;
         lock.unlock();
         receiver.close();
         continue;
      }

      // Start request
      Request request = new Request(headers, requestData);
      Output  output = new Output(receiver);
      
      bool exit = false;

      try { handler(request, output); }
      
      // Unhandled Exception escape from user code
      catch (Exception e) 
      { 
         if (!output.headersSent) 
            output.status = 501; 
         
         reservedLog(format("Uncatched exception: %s", e.msg)); 
      }

      // Even worst.
      catch (Throwable t) 
      { 
         if (!output.headersSent) 
            output.status = 501; 
          
          reservedLog(format("Throwable: %s", t.msg)); 
          exit = true;
      }
      finally 
      { 
         receiver.close();
      }
      
      lock.unlock();

      if(exit == true) break;
   }
}

/// Write a formatted log
void reservedLog(T...)(T params)
{
   import std.datetime : SysTime, Clock;
   import std.conv : to;
   import std.process : thisProcessID;
   import std.stdio : write, writef, writeln, stdout;

   SysTime t = Clock.currTime;

   writef(
      "%04d/%02d/%02d %02d:%02d:%02d.%s [%s] >>> ", 
      t.year, t.month, t.day, t.hour,t.minute,t.second,t.fracSecs.split!"msecs".msecs, thisProcessID()
   );

   foreach (p; params)
      write(p.to!string, " ");
   
   writeln;
   stdout.flush;
}

/// A cookie
struct Cookie
{
   string      name;       /// Cookie data
   string      value;      /// ditto
   string      path;       /// ditto
   string      domain;     /// ditto

   DateTime    expire;     /// ditto

   bool        session     = true;  /// ditto  
   bool        secure      = false; /// ditto
   bool        httpOnly    = false; /// ditto

   /// Invalidate cookie
   public void invalidate()
   {
      expire = DateTime(1970,1,1,0,0,0);
   }
}

/// A request from user
class Request 
{ 

   /// HTTP methods
   public enum Method
	{
		Get, ///
      Post, ///
      Head, ///
      Delete, ///
      Put, ///
      Unknown = -1 ///
	}
	
   @disable this();

   private this(string[string] headers, char[] requestData) 
   {
      import std.regex : match, ctRegex;
      import std.uri : decodeComponent;
		import std.string : translate, split;

      // Reset values
		_header  = headers;
      _get 	   = (typeof(_get)).init;
      _post 	= (typeof(_post)).init;
      _cookie  = (typeof(_cookie)).init;
      _data 	= requestData;

		// Read get params
      if ("QUERY_STRING" in _header)
         foreach(m; match(_header["QUERY_STRING"], ctRegex!("([^=&]+)(?:=([^&]+))?&?", "g")))
            _get[m.captures[1].decodeComponent] = translate(m.captures[2], ['+' : ' ']).decodeComponent;

      // Read post params
      if ("REQUEST_METHOD" in _header && _header["REQUEST_METHOD"] == "POST")
         if(_data.length > 0 && split(_header["CONTENT_TYPE"].toLower(),";")[0] == "application/x-www-form-urlencoded")
            foreach(m; match(_data, ctRegex!("([^=&]+)(?:=([^&]+))?&?", "g")))
               _post[m.captures[1].decodeComponent] = translate(m.captures[2], ['+' : ' ']).decodeComponent;

      // Read cookies
      if ("HTTP_COOKIE" in _header)
         foreach(m; match(_header["HTTP_COOKIE"], ctRegex!("([^=]+)=([^;]+);? ?", "g")))
            _cookie[m.captures[1].decodeComponent] = m.captures[2].decodeComponent;

   }

   ///
   @nogc @property nothrow public const(char[]) data() const  { return _data; } 
	
   ///
   @nogc @property nothrow public const(string[string]) get() const { return _get; }
   
   ///
   @nogc @property nothrow public const(string[string]) post()  const { return _post; }
   
   ///
   @nogc @property nothrow public const(string[string]) header() const { return _header; } 
   
   ///
   @nogc @property nothrow public const(string[string]) cookie() const { return _cookie; }  
   
	///
   @property public Method method() const
	{
		switch(_header["REQUEST_METHOD"].toLower())
		{
			case "get": return Method.Get;
			case "post": return Method.Post;
			case "head": return Method.Head;
			case "put": return Method.Put;
			case "delete": return Method.Delete;
         default: return Method.Unknown;  
		}      
	}

   private char[] _data;
   private string[string]  _get;
   private string[string]  _post;
   private string[string]  _header;
	private string[string]  _cookie;
}

/// Your reply.
class Output
{
	private struct KeyValue
	{
		this (in string key, in string value) { this.key = key; this.value = value; }
		string key;
		string value;
	}
	
   @disable this();

   private this(Socket socket)
   {
      _socket        = socket;
      _status		   = 200;
		_headersSent   = false;
   }

   /// You can add a http header. But you can't if body is already sent.
	public void addHeader(in string key, in string value) 
   {
      if (_headersSent) 
         throw new Exception("Can't add/edit headers. Too late. Just sent.");

      _headers ~= KeyValue(key, value); 
   }

	/// Force sending of headers.
	public void sendHeaders()
   {
      if (_headersSent) 
         throw new Exception("Can't resend headers. Too late. Just sent.");

      import std.uri : encode;

      bool has_content_type = false;
      _socket.send(format("Status: %s\r\n", _status));

      // send user-defined headers
      foreach(header; _headers)
      {
         _socket.send(format("%s: %s\r\n", header.key, header.value));
         if (header.key.toLower() == "content-type") has_content_type = true;
      }

      // Default content-type is text/html if not defined by user
      if (!has_content_type)
         _socket.send(format("content-type: text/html; charset=utf-8\r\n"));
      
      // If required, I add headers to write cookies
      foreach(Cookie c; _cookies)
      {

         _socket.send(format("Set-Cookie: %s=%s", c.name.encode(), c.value.encode()));
   
         if (!c.session)
         {
            string[] mm = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            string[] dd = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

            string data = format("%s, %s %s %s %s:%s:%s GMT",
               dd[c.expire.dayOfWeek], c.expire.day, mm[c.expire.month], c.expire.year, 
               c.expire.hour, c.expire.minute, c.expire.second
            );

            _socket.send(format("; Expires: %s", data));
         }

         if (!c.path.length == 0) _socket.send(format("; path=%s", c.path));
         if (!c.domain.length == 0) _socket.send(format("; domain=%s", c.domain));

         if (c.secure) _socket.send(format("; Secure"));
         if (c.httpOnly) _socket.send(format("; HttpOnly"));

         _socket.send("\r\n");
      }
   
      _socket.send("\r\n");
      _headersSent = true;
   }
	
   /// You can set a cookie.  But you can't if body is already sent.
   public void setCookie(Cookie c)
   {
      if (_headersSent) 
         throw new Exception("Can't set cookies. Too late. Just sent.");
      
      _cookies ~= c;
   }
	
   /// Retrieve all cookies
   @nogc @property nothrow public Cookie[]  cookies() 				{ return _cookies; }
	
   /// Output status
   @nogc @property nothrow public ulong 		status() 				{ return _status; }
	
   /// Set response status. Default is 200 (OK)
   @property public void 		               status(ulong status) 
   {
      if (_headersSent) 
         throw new Exception("Can't set status. Too late. Just sent.");

      _status = status; 
   }

   /**
   * Syntax sugar to write data
   * Example:
   * --------------------
   * output ~= "Hello world";
   * --------------------
   */ 
	public void opOpAssign(string op, T)(T data) if (op == "~")  { import std.conv : to; write(data.to!string); }

   /// Write data
   public void write(string data) { import std.string : representation; write(data.representation); }
   
   /// Ditto
   public void write(in void[] data) 
   {
      if (!_headersSent) 
         sendHeaders(); 
      
      _socket.send(data); 
   }
   
   /// Are headers already sent?
   @nogc nothrow public bool headersSent() { return _headersSent; }

	private bool			   _headersSent = false;
	private Cookie[]      	_cookies;
	private KeyValue[]  	   _headers;
   private ulong           _status = 200;
		
	private Socket          _socket;
}
