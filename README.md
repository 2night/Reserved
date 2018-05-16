# Reserved
A [scgi](https://en.wikipedia.org/wiki/Simple_Common_Gateway_Interface) client for D programming language. Doc: [dpldocs]( http://reserved.dpldocs.info)

# The simple way

```d
import reserved;
import std.stdio;

@ReservedResponse
private void response(Request req, Output output)
{
   output ~= "Hello ";
   
   if ("name" in req.get) 
      output ~= req.get["name"];
   else 
      output ~= "World";
}

mixin Reserved!"awesome_d_webservice";
```

Starting this example will create a socket named ```/tmp/run/awesome_d_webservice/listener.0.sock```.
If another process is still running on the same socket it will be (gracefully) killed.

# Configure the server

To make nginx (for example) working with reserved just add these lines on its config file (on ubuntu: ```/etc/nginx/sites-available/default```) and restart nginx:

```
location / {
                include   scgi_params;
                scgi_pass unix:/tmp/run/awesome_d_webservice/listener.0.sock;
        }
```

Pay attention to sock file permission. Both your application and nginx must have permission to read/write that file. The easy way is to run both with the same user.

# Init function

If you need to call a one-time-init function, you can annotate it with ```@ReservedInit```.
Its signature must be one of these:

```d
bool init()

// will be called using main() args
bool init(string[] args)
```

It musts return true on success.

# Multiple responders

If you want to run multiple parallel responders, just use ```-i``` options on command line. For example ```./your_app -i 3``` will create a socket named ```/tmp/run/awesome_d_webservice/listener.3.sock``` and/or will kill any process running on it.



