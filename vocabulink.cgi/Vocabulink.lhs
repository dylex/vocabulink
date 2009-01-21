\documentclass[oneside]{article}
%include polycode.fmt
\usepackage[T1]{fontenc}
\usepackage{ucs}
\usepackage[utf8]{inputenc}
\usepackage{hyperref}
\usepackage[pdftex]{graphicx}
\usepackage[x11names, rgb]{xcolor}
\usepackage{tikz}
\usetikzlibrary{decorations,arrows,shapes}
\usepackage[margin=1.4in]{geometry}

\hypersetup{colorlinks=true}

\title{Vocabulink}
\author{Chris Forno (jekor)}
\date{January 16, 2009}

\begin{document}
\maketitle

\section{Introduction}

This is the main Vocabulink program. It is spawned as a FastCGI process and
handles all web requests for vocabulink.com.

Vocabulink.cgi is essentially a multi-user application which operates via the
web. It's structured like a standalone application inasmuch as it handles
multiple requests in a single multi-threaded process. Yet, it's structured like
a CGI program in that it communicates to the outside world through a web
server. It's also designed with the assumption that it may be only 1 of many
processes and that it doesn't have exclusive access to resources such as a
database.

\subsection{Architecture}

Requests arrive via a webserver. They are passed to the vocabulink.fcgi process
(this program) on TCP port 10033.

Upon receiving a request (connection), we immediately fork a new thread. In
this thread, we establish a connection to a PostgreSQL server (for each
request). We then examine the thread for an authentication cookie. If it exists
and is valid, we assume that the request is from an authenticated member. We
pack both the database handle and the authenticated member information into our
``App'' monad (\autoref{App}).

> module Main where

\section{Our Modules}

These are the Vocabulink modules. They are grouped primarily based on division
of labor. The exception is the App module. The App module defines the App monad
and must make use of both database and CGI functions. In order to limit
cyclical dependencies (which can be a pain with the GHC compiler), it's broken
out into a separate module.

> import Vocabulink.App

Each of these modules will be described in its own section.

> import Vocabulink.Article
> import Vocabulink.CGI
> import Vocabulink.Html
> import Vocabulink.Link
> import Vocabulink.Member
> import Vocabulink.Review
> import Vocabulink.Utils
> import Vocabulink.Widget
> import Vocabulink.Widget.MyLinks

\section{Other Modules}

Vocabulink makes use of a half dozen or so Haskell libraries. Even though we don't use them all in this module, I'll describe them here so that they'll be more familiar as they're introduced (and so that you can jump directly to the section you're interested in after this introduction).

\begin{description}
\item[Codec.Binary.UTF8.String] Vocabulink would be pretty useless without being able to handle the writing systems of other languages. We only make use of 2 functions provided by this library: |encodeString| and |decodeString|. |decodeString| takes a UTF-8 string---either from the webserver or from the database---and converts it into a Unicode string that can be used by Haskell natively. We use |encodeString| to go in the other direction. Whenever we write out a string to the database, the webserver, or a log file; it needs to be encoded to UTF-8. This is something that the type system does not (yet) handle for us, so we need to be careful to correctly encode and decode strings.
\item[Network.URI] Various parts of the code may need to construct or deconstruct URLs. Using this library should be safer than using various string-mangling techniques throughout the code.
\item[Text.ParserCombinators.Parsec] We need to parse text quite a bit. The dispatcher, the member authentication routines, and the article publishing system all make use of Parsec; and probably more will in the future.
\item[System.Time] This is actually a deprecated library for handling time. However, the database library HDBC requires it. It's unfortunate, because this library is a bit of a mess.
\end{description}

There are a few more, but they are only used by a single Vocabulink module\footnote{The Vocabulink module may re-export some functions provided by the module, but the other Vocabulink modules should be able to remain ignorant of that.}.

> import Codec.Binary.UTF8.String (decodeString)
> import Control.Concurrent (forkIO)
> import Control.Monad.Reader (asks)
> import Data.List (find, intercalate)
> import Data.Maybe (isJust)
> import Network.FastCGI (runFastCGIConcurrent')
> import Network.URI (URI(..), unEscapeString)

\section{Entry and Dispatch}

When the program starts, it immediately begin listening for connections.
|runFastCGIConcurrent'| spawns up to 10 threads. |handleErrors'| and |runApp|
will be explained later. The basically catch unhandled database errors and pack
information into the App monad.

TODO: Before public launch, the thread limit needs to be increased.

> main :: IO ()
> main =  runFastCGIConcurrent' forkIO 10 (handleErrors' (runApp handleRequest))

|handleRequest| ``digests'' the requested URI before passing it to the
 dispatcher. It also sets the response header. If we ever serve up non-HTML
 content, the header will need to be set at a lower level.

> handleRequest :: App CGIResult
> handleRequest = do
>   uri     <- requestURI
>   method  <- requestMethod
>   setHeader "Content-Type" "text/html; charset=utf-8"
>   let path = pathList uri
>   dispatch' method path

We extract the path part of the URI, ``unescape it'' (convert % codes back to
characters), decode it (convert \mbox{UTF-8} characters to Unicode Chars), and finally
parse it into directory and filename components.

\begin{quote}@/some/directory/and/a/filename@\end{quote}

becomes

\begin{quote}|["some","directory","and","a","filename"]|\end{quote}

Note that the parser does not have to deal with query strings or fragments
because |uriPath| has already stripped them.

The one case this doesn't handle correctly is //something, because it's handled
differently by |Network.CGI|.

> pathList :: URI -> [String]
> pathList = split (== '/') . decodeString . unEscapeString . uriPath

I used to use a parser for this instead of split, but it got tricky.

> -- pathComponents :: Parser [String]
> -- pathComponents =  many1 (char '/') >> sepEndBy (many (noneOf "/")) (char '/')

Before we actually dispatch the request, we use the opportunity to clean up the
URI and redirect the client if necessary. This handles cases like trailing
slashes. We want only one URI to point to a resource.

> dispatch' :: String -> [String] -> App CGIResult
> dispatch' method path =
>   case path of
>     ["",""] -> frontPage {- "/" -}
>     ("":xs) -> case find (== "") xs of
>                  Nothing -> dispatch method xs
>                  Just _  -> redirect $ "/" ++ (intercalate "/" $ filter (/= "") xs)
>     _       -> output404 []

Here is where we dispatch each request to a function. We can match the request
on method and path components. This means that we can dispatch a request to one
function for a @GET@ and to another for a @POST@.

> dispatch :: String -> [String] -> App CGIResult

\subsection{Static Files}

Some URIs are nothing fancier than static HTML files. We serve them from within the program so that we can wrap them in a header, footer, and whatever else we'd like.

Each @.html@ file is actually an HTML fragment. These happen to be generated
from Muse Mode files by Emacs, but we don't really care where they come from.

These are the links in the standard page footer.

> dispatch "GET" ["privacy"]     = displayStaticFile "Privacy Policy" $
>                                  staticPath ++ "privacy.html"
> dispatch "GET" ["help"]        = displayStaticFile "Help" $
>                                  staticPath ++ "help.html"
> dispatch "GET" ["copyrights"]  = displayStaticFile "Copyright Policy" $
>                                  staticPath ++ "copyrights.html"
> dispatch "GET" ["disclaimer"]  = displayStaticFile "Disclaimer" $
>                                  staticPath ++ "disclaimer.html"

\subsection{Articles}

Articles are also static files, but we want to be able to add new articles
without recompiling. Also, we extract some extra information from articles. See
\autoref{Article}.

Each article is accessed at @/article/title@.

> dispatch "GET" ["article",x] = articlePage x

A listing is presented at @/articles@. I'm still debating whether or not it
should be @/article/@.

> dispatch "GET" ["articles"] = articlesPage

\subsection{Link Pages}

Vocabulink revolves around links---the associations between words or ideas. As
with articles, we have different functions for retrieving a single link or a
listing of links. However, the dispatching is complicated by the fact that
members can operate upon links (we need to handle the @POST@ method).

If we could rely on the @DELETE@ method being supported, this would be a little
less ugly. However, I've decided to only use @GET@ and @POST@. All other
methods are appended as an extra path component (here, as |method'|). I'm not
100\% satisfied with this design decision, but I haven't thought of a better way
yet.

For clarity, this dispatches:

\begin{center}
\begin{tabular}{lcl}
@GET /link/10@            & $\rightarrow$ & linkPage\\
@GET /link/something@     & $\rightarrow$ & not found\\
@GET /link/10/something@  & $\rightarrow$ & not found\\
@POST /link/10/delete@    & $\rightarrow$ & deleteLink\\
\end{tabular}
\end{center}

> dispatch method ("link":x:method') = do
>   linkNo <- liftIO $ intFromString x
>   case linkNo of
>     Nothing  -> output404 ["Links are identified by numbers only."]
>     Just n   -> case (method, method') of
>                   ("GET"   ,[])          -> linkPage n
>                   ("POST"  ,["delete"])  -> deleteLink n
>                   (m       ,xs)          -> output404 (m:xs)

Retrieving a listing of links is easier.

> dispatch "GET" ["links"] = linksPage

Creating a new link is a 2-step process. First, the member must request a page
on which to enter information about the link. Then they @POST@ the details to
establish the link.

> dispatch "GET"   ["link"] = newLinkPage
> dispatch "POST"  ["link"] = linkLexemes

\subsection{Lexeme Pages}

Links are made out of pairs of lexemes (see the handbook section on lexemes in
the Links chapter). They don't actually exist in the database because we don't
need to know anything about them other than their textual representation.

> dispatch "GET" ["lexeme",x] = lexemePage x

\subsection{Link Review}

Each link for review can be added to a set. Most people will only use their
default (unnamed) set.

> dispatch method' ("review":xs) =
>   withMemberNumber $ \memberNo ->
>     case (method',xs) of
>       ("GET",["next"])   -> reviewLink memberNo
>       ("POST",["set",x]) -> newReview memberNo x
>       ("POST",[x])       -> linkReviewed' memberNo x
>       (m,x)              -> output404 (m:x)

> dispatch "GET"  ["member","join"] = newMemberPage
> dispatch "POST" ["member","join"] = addMember'
> dispatch "GET"  ["member","login"] = loginPage
> dispatch "POST" ["member","login"] = login
> dispatch "POST" ["member","logout"] = logout

All searching for links is currently done by searching for a lexeme on either
side.

> dispatch "GET" ["search"] = searchPage

It would be nice to automatically respond with "Method Not Allowed" on pages
that exist but don't take the POST/whatever method (as opposed to responding
with 404).

> dispatch "GET" _ = output404 []
> dispatch "POST" _ = outputError 404 "Resource not found or POST not allowed on it." []

> dispatch _ _ = outputMethodNotAllowed ["GET", "POST"]

This path to static files will change once it's launched to the live site.

> staticPath :: FilePath
> staticPath = "/home/chris/project/vocabulink/static/"

To display a static file, we simply read it into memory and wrap it with the
standard page template.

Use this only if you know that the static file will be a valid fragment of XHTML.

> displayStaticFile :: String -> FilePath -> App CGIResult
> displayStaticFile t path = do
>   body <- liftIO $ readFile path
>   stdPage t [] [primHtml body]

> frontPage :: App CGIResult
> frontPage = do
>   memberNo <- asks memberNumber
>   w <- isJust memberNo ? renderWidget (MyLinks 10) $ return noHtml
>   stdPage "Welcome to Vocabulink" []
>     [ h1 << "Welcome to Vocabulink",
>       w ]

%include Vocabulink/Utils.lhs
%include Vocabulink/CGI.lhs
%include Vocabulink/DB.lhs
%include Vocabulink/Html.lhs
%include Vocabulink/App.lhs
%include Vocabulink/Member.lhs
%include Vocabulink/Member/Auth.lhs
%include Vocabulink/Link.lhs
%include Vocabulink/Link/Types.lhs
%include Vocabulink/Review.lhs
%include Vocabulink/Review/Html.lhs
%include Vocabulink/Review/SM2.lhs
%include Vocabulink/Article.lhs
%include Vocabulink/Widget.lhs
%include Vocabulink/Widget/MyLinks.lhs

\end{document}