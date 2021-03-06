-- Copyright 2008, 2009, 2010, 2011, 2012, 2013 Chris Forno

-- This file is part of Vocabulink.

-- Vocabulink is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version.

-- Vocabulink is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
-- for more details.

-- You should have received a copy of the GNU Affero General Public License
-- along with Vocabulink. If not, see <http://www.gnu.org/licenses/>.

-- Introduction

-- This is Vocabulink, the SCGI program that handles all web requests for
-- http://www.vocabulink.com/. The site helps people learn languages through
-- fiction. It provides a mnemonics database and spaced repetion (review)
-- tools.

-- Architecture

-- Requests arrive via a webserver. (I'm currently using lighttpd, but it
-- should work with any server that supports SCGI.) They are passed to the
-- vocabulink.cgi process (this program) on TCP port 10033 of the local
-- loopback interface.

-- Upon receiving a request (connection), we immediately fork a new thread. In
-- this thread, we establish a connection to a PostgreSQL server (for each
-- request). We then examine the request for an authentication cookie. If it
-- exists and is valid, we consider the request to have originated from an
-- authenticated member. We pack both the database handle and the authenticated
-- member information into our App monad and then pass control to a function
-- based on the request method and URI.

module Main where

import Vocabulink.Article
import Vocabulink.CGI
import Vocabulink.Comment
import Vocabulink.Env
import Vocabulink.Html hiding (method)
import Vocabulink.Link
import Vocabulink.Member
import Vocabulink.Member.Html
import Vocabulink.Member.Registration
import Vocabulink.Page
import Vocabulink.Reader
import Vocabulink.Review
import Vocabulink.Utils

import Prelude hiding (div, span, id, words)

import Control.Concurrent (forkIO)
import Control.Exception (finally, SomeException)
import Control.Monad (forever)
import Control.Monad.Catch (MonadCatch(..))
import Control.Monad.State (State, runState, get, put)
import qualified Data.ByteString.UTF8 as BU
import qualified Data.ByteString.Lazy.UTF8 as BLU
import Data.Int (Int32, Int64)
import Data.List (find, genericLength)
import Database.TemplatePG (pgConnect, defaultPGDatabase, PGDatabase(..))
import Network (accept)
import Network.Socket (listen, Socket(..), getAddrInfo, socket, Family(..), SocketType(..), defaultProtocol, bind, addrAddress, SocketOption(..), setSocketOption)
import qualified Network.SCGI as SCGI
import Network.URI (unEscapeString)
import System.IO (hClose)
import System.Random (StdGen, Random, getStdGen, setStdGen, randomR)
import Web.Cookie (parseCookies)

main :: IO ()
main = do
  s <- listenLocal "10033"
  forever $ do
    (handle, _, _) <- accept s
    _ <- forkIO $ finally (SCGI.runRequest handle (catch handleRequest handleError))
                          (hClose handle)
    return ()
 where listenLocal :: String -> IO Socket
       listenLocal port = do
         addrs <- getAddrInfo Nothing (Just "127.0.0.1") (Just port)
         s <- socket AF_INET Stream defaultProtocol
         setSocketOption s ReuseAddr 1
         bind s $ addrAddress $ head addrs
         listen s 5
         return s
       handleError :: SomeException -> SCGI Response
       handleError = bounce MsgError . show

handleRequest :: SCGI Response
handleRequest = do
  db <- liftIO $ pgConnect $ defaultPGDatabase { pgDBName = "vocabulink", pgDBUser = "vocabulink", pgDBPass = dbPassword }
  member <- loggedIn db
  -- This is here to avoid IO in the Page module.
  due <- case member of
           Nothing -> return 0
           Just m -> liftIO $ (fromJust . fromJust) `liftM` $(queryTuple
                       "SELECT COUNT(*) FROM link_to_review \
                       \INNER JOIN link USING (link_no) \
                       \WHERE member_no = {memberNumber m} \
                         \AND learn_lang = 'es' AND known_lang = 'en' \
                         \AND current_timestamp > target_time \
                         \AND NOT deleted") db
  method' <- SCGI.method
  path' <- SCGI.path
  case (method', path') of
    (Just method, Just path) -> let ?db = db
                                    ?member = member
                                    ?numDue = due in dispatch' (BU.toString method) (pathList $ BU.toString path)
    _ -> error "Missing request method or path."
 where loggedIn db = do
         auth <- (lookup "auth" . parseCookies =<<) `liftM` SCGI.header "HTTP_COOKIE"
         token' <- liftIO $ maybe (return Nothing) (validAuth . BU.toString) auth
         case token' of
           Nothing -> return Nothing
           Just token -> do
             -- We want to renew the expiry of the auth token if the user
             -- remains active. But we don't want to be sending out a new
             -- cookie with every request. Instead, we check to see that one
             -- day has passed since the auth cookie was set. If so, we refresh
             -- it.
             now <- liftIO epochTime
             when (authExpiry token - now < authShelfLife - (24 * 60 * 60)) $ do
               setCookie =<< liftIO (authCookie $ authMemberNumber token)
             row <- liftIO $ $(queryTuple
                      "SELECT username, email FROM member \
                      \WHERE member_no = {authMemberNumber token}") db
             return $ liftM (\(username, email) -> Member { memberNumber = authMemberNumber token
                                                          , memberName   = username
                                                          , memberEmail  = email
                                                          }) row

-- We extract the path part of the URI, ``unescape it'' (convert % codes back
-- to characters), decode it (convert UTF-8 characters to Unicode Chars), and
-- finally parse it into directory and filename components. For example,

-- /some/directory/and/a/filename

-- becomes

-- ["some","directory","and","a","filename"]

-- Note that the parser does not have to deal with query strings or fragments
-- because |uriPath| has already stripped them.

-- The one case this doesn't handle correctly is @//something@, because it's
-- handled differently by |Network.CGI|.

pathList :: String -> [String]
pathList = splitOn "/" . unEscapeString

-- Before we actually dispatch the request, we use the opportunity to clean up
-- the URI and redirect the client if necessary. This handles cases like
-- trailing slashes. We want only one URI to point to a resource.

dispatch' :: E (String -> [String] -> SCGI Response)
dispatch' meth path =
  case path of
    ["",""] -> toResponse $ frontPage -- "/"
    ("":xs) -> case find (== "") xs of
                 Nothing -> dispatch meth xs
                 Just _  -> redirect $ '/' : intercalate "/" (filter (/= "") xs)
    _       -> return notFound

-- Here is where we dispatch each request to a function. We can match the
-- request on method and path components. This means that we can dispatch a
-- @GET@ request to one function and a @POST@ request to another.

dispatch :: E (String -> [String] -> SCGI Response)

-- Articles

-- Some permanent URIs are essentially static files. To display them, we make
-- use of the article system (formatting, metadata, etc). You could call these
-- elevated articles. We use articles because the system for managing them
-- exists already (revision control, etc)

-- Each @.html@ file is actually an HTML fragment. These happen to be generated
-- from Muse Mode files by Emacs, but we don't really care where they come
-- from.

dispatch "GET" ["help"]         = bounce MsgSuccess "Just testing, escaping." -- toResponse $ articlePage "help"
dispatch "GET" ["privacy"]      = toResponse $ articlePage "privacy"
dispatch "GET" ["terms-of-use"] = toResponse $ articlePage "terms-of-use"
dispatch "GET" ["source"]       = toResponse $ articlePage "source"
dispatch "GET" ["api"]          = toResponse $ articlePage "api"
dispatch "GET" ["download"]     = redirect "https://github.com/jekor/vocabulink/tarball/master"

-- Other articles are dynamic and can be created without recompilation. We just
-- have to rescan the filesystem for them. They also live in the @/article@
-- namespace (specifically at @/article/title@).

dispatch "GET" ["article",x] = toResponse $ articlePage x

-- We have 1 page for getting a listing of all published articles.

dispatch "GET" ["articles"] = toResponse $ articlesPage

-- Link Pages

-- Vocabulink revolves around links---the associations between words or ideas. As
-- with articles, we have different functions for retrieving a single link or a
-- listing of links. However, the dispatching is complicated by the fact that
-- members can operate upon links (we need to handle the @POST@ method).

-- For clarity, this dispatches:

-- GET    /link/10               → link page
-- POST   /link/10/stories       → add a linkword story

dispatch meth ["link","story",x] =
  case readMaybe x of
    Nothing -> return notFound
    Just n  -> case meth of
                 "GET" -> toResponse $ getStory n
                 "PUT" -> do
                   story <- SCGI.body
                   liftIO $ editStory n (BLU.toString story)
                   return emptyResponse
                 -- temporarily allow POST until AJAX forms are better
                 "POST" -> do
                   story <- bodyVarRequired "story"
                   liftIO $ editStory n story
                   redirect =<< referrerOrVocabulink -- TODO: This redirect masks the result of editStory
                 _ -> return notAllowed

dispatch meth ("link":x:part) =
  case readMaybe x of
    Nothing -> return notFound
    Just n  -> case (meth, part) of
                 ("GET", []) -> do
                   link' <- liftIO $ linkDetails n
                   reps <- SCGI.negotiate ["application/json", "text/html"]
                   case (reps, link') of
                     (("application/json":_), Just link) -> toResponse $ toJSON link
                     (("text/html":_), Just link) -> toResponse $ linkPage link
                     _ -> return notFound
                 ("GET", ["stories"]) -> do
                   -- TODO: Support HTML/JSON output based on content-type negotiation.
                   stories <- liftIO $ linkStories n
                   toResponse $ mconcat $ map toMarkup stories
                 ("POST", ["stories"]) -> do
                   story <- bodyVarRequired "story"
                   liftIO $ addStory n story
                   redirect $ "/link/" ++ show n -- TODO: This redirect masks the result of addStory
                 _ -> return notAllowed

-- Retrieving a listing of links is easier.

dispatch "GET" ["links"] = do
  ol' <- queryVar "ol"
  dl' <- queryVar "dl"
  case (ol', dl') of
    (Just ol, Just dl)  -> do
      case (lookup ol languages, lookup dl languages) of
        (Just olang, Just dlang) -> do links <- liftIO $ languagePairLinks ol dl
                                       toResponse $ linksPage ("Links from " ++ olang ++ " to " ++ dlang) links
        _                        -> return notFound
    _ -> return notFound

-- Readers

dispatch "GET" ["reader", lang, name'] = toResponse $ readerTitlePage lang name'
dispatch "GET" ["reader", lang, name', pg] = case readMaybe pg of
                                               Nothing -> return notFound
                                               Just n  -> toResponse $ readerPage lang name' n

-- Searching

dispatch "GET" ["search"] = do
  q <- queryVarRequired "q"
  links <- if q == ""
              then return []
              else liftIO $ linksContaining q
  toResponse $ linksPage ("Search Results for \"" ++ q ++ "\"") links

-- Languages

-- Browsing through every link on the site doesn't work with a significant
-- number of links. A languages page shows what's available and contains
-- hyperlinks to language-specific browsing.

dispatch "GET" ["languages"] = permRedirect "/links"

-- Learning

dispatch "GET" ["learn"] = do
  learn <- queryVarRequired "learn"
  known <- queryVarRequired "known"
  case (lookup learn languages, lookup known languages) of
    (Just _, Just _) -> toResponse $ learnPage learn known
    _ -> return notFound
dispatch "GET" ["learn", "upcoming"] = do
  learn <- queryVarRequired "learn"
  known <- queryVarRequired "known"
  n <- read `liftM` queryVarRequired "n"
  toResponse $ upcomingLinks learn known n

-- Link Review

-- Members review their links by interacting with the site in a vaguely
-- REST-ish way. The intent behind this is that in the future they will be able
-- to review their links through different means such as a desktop program or a
-- phone application.

-- PUT  /review/n     → add a link for review
-- GET  /review/next  → retrieve the next links for review
-- GET  /review/upcoming?until=timestamp → retrieve upcoming links for review
-- POST /review/n     → mark link as reviewed

-- (where n is the link number)

-- Reviewing links is one of the only things that logged-in-but-unverified
-- members are allowed to do.

dispatch meth ("review":rpath) = do
  case ?member of
    Nothing -> return notFound
    Just m ->
      case (meth, rpath) of
        ("GET",  ["stats"])    -> toResponse . toJSON =<< liftIO (reviewStats m)
        ("GET",  ["stats",x])  -> do
          start <- read `liftM` queryVarRequired "start"
          end   <- read `liftM` queryVarRequired "end"
          tzOffset <- queryVarRequired "tzoffset"
          case x of
            "daily"    -> toResponse . toJSON =<< liftIO (dailyReviewStats m start end tzOffset)
            "detailed" -> toResponse . toJSON =<< liftIO (detailedReviewStats m start end tzOffset)
            _          -> return notFound
        ("PUT",  [x]) ->
          case readMaybe x of
            Nothing -> error "Link number must be an integer"
            Just n  -> liftIO (newReview m n) >> return emptyResponse
        ("POST", ["sync"]) -> do
          clientSync <- bodyJSON
          case clientSync of
            Nothing -> error "Invalid sync object."
            Just (ClientLinkSync retain) -> toResponse $ syncLinks m retain
        ("POST", [x]) ->
          case readMaybe x of
            Nothing -> error "Link number must be an integer"
            Just n  -> do
              grade <- read `liftM` bodyVarRequired "grade"
              recallTime <- read `liftM` bodyVarRequired "time"
              reviewedAt' <- maybe Nothing readMaybe `liftM` bodyVar "when"
              reviewedAt <- case reviewedAt' of
                              Nothing -> liftIO epochTime
                              Just ra -> return ra
              -- TODO: Sanity-check this time. It should at least not be in the future.
              liftIO $ scheduleNextReview m n grade recallTime reviewedAt
              return emptyResponse
        _ -> return notFound

-- Dashboard

dispatch "GET" ["dashboard"] = withLoggedInMember $ const $ toResponse dashboardPage

-- Membership

-- Becoming a member is simply a matter of filling out a form.

-- Note that in some places where I would use a PUT I've had to append a verb
-- to the URL and use a POST instead because these requests are often made to
-- HTTPS pages from HTTP pages and can't be done in JavaScript without a lot of
-- not-well-supported cross-domain policy hacking.

dispatch "POST" ["member","signup"] = signup

-- But to use most of the site, we require email confirmation.

dispatch "GET" ["member","confirmation",x] = confirmEmail x
dispatch "POST" ["member","confirmation"] =
  case ?member of
    Nothing -> do
      toResponse $ simplePage "Please Login to Resend Your Confirmation Email" [ReadyJS "V.loginPopup();"] mempty
    Just m  -> do
      liftIO $ resendConfirmEmail m
      bounce MsgSuccess "Your confirmation email has been sent."

-- Logging in is a similar process.

dispatch "POST" ["member","login"] = login

-- Logging out can be done without a form.

dispatch "POST" ["member","logout"] = logout

dispatch "POST" ["member","delete"] = deleteAccount

dispatch "POST" ["member","password","reset"] = do
  email <- bodyVarRequired "email"
  liftIO $ sendPasswordReset email
  return emptyResponse
dispatch "GET"  ["member","password","reset",x] = toResponse $ passwordResetPage x
dispatch "POST" ["member","password","reset",x] = passwordReset x
dispatch "POST" ["member","password","change"] = changePassword
dispatch "POST" ["member","email","change"] = changeEmail

-- Member Pages

dispatch "GET" ["user", username] = toResponse $ memberPage <$$> memberByName username
dispatch "GET" ["user", username, "available"] = toResponse . toJSON =<< liftIO (usernameAvailable username)
dispatch "GET" ["email", email, "available"] = toResponse . toJSON =<< liftIO (emailAvailable email)

-- ``reply'' is used here as a noun.

dispatch meth ("comment":x:meth') =
  case readMaybe x of
    Nothing -> return notFound
    Just n  -> case (meth, meth') of
                 -- Every comment posted is actually a reply thanks to the fake root comment.
                 ("POST", ["reply"]) -> do
                   body <- bodyVarRequired "body"
                   withVerifiedMember (\m -> liftIO $ storeComment (memberNumber m) body (Just n))
                   redirect =<< referrerOrVocabulink
                 _ -> return notFound

-- Everything Else

-- For Google Webmaster Tools, we need to respond to a certain URI that acts as
-- a kind of ``yes, we really do run this site''.

dispatch "GET" ["google1e7c25c4bdfc5be7.html"] = toResponse ("google-site-verification: google1e7c25c4bdfc5be7.html"::String)

dispatch "GET" ["robots.txt"] = toResponse $ unlines [ "User-agent: *"
                                                     , "Disallow:"
                                                     ]

-- It would be nice to automatically respond with ``Method Not Allowed'' on
-- URIs that exist but don't make sense for the requested method (presumably
-- @POST@). However, we need to take a simpler approach because of how the
-- dispatch method was designed (pattern matching is limited). We output a
-- qualified 404 error.

dispatch _ _ = return notFound

-- Finally, we get to an actual page of the site: the front page.

frontPage :: E (IO Html)
frontPage = do
  let limit = 40 :: Int64
  words <- case ?member of
    -- Logged in? Use the words the person has learned.
    Just m -> $(queryTuples
      "SELECT learn, link_no FROM link \
      \WHERE NOT deleted AND link_no IN \
       \(SELECT DISTINCT link_no FROM link_to_review \
        \WHERE member_no = {memberNumber m}) \
        \ORDER BY random() LIMIT {limit}") ?db
    -- Not logged in? Use words with stories.
    Nothing -> $(queryTuples
      "SELECT learn, link_no FROM link \
      \WHERE NOT deleted AND link_no IN \
       \(SELECT DISTINCT link_no FROM linkword_story) \
        \ORDER BY random() LIMIT {limit}") ?db
  cloud <- wordCloud words 261 248 12 32 6
  nEsLinks <- fromJust . fromJust <$> $(queryTuple "SELECT COUNT(*) FROM link WHERE learn_lang = 'es' AND known_lang = 'en' AND NOT deleted") ?db
  nReviews <- fromJust . fromJust <$> $(queryTuple "SELECT COUNT(*) FROM link_review") ?db
  nLinkwords <- fromJust . fromJust <$> $(queryTuple "SELECT COUNT(*) FROM link WHERE linkword IS NOT NULL AND NOT deleted") ?db
  nStories <- fromJust . fromJust <$> $(queryTuple "SELECT COUNT(*) FROM linkword_story INNER JOIN link USING (link_no) WHERE NOT deleted") ?db
  return $ stdPage "Learn Vocabulary Fast with Linkword Mnemonics" [CSS "front"] mempty $
    mconcat [
      div ! class_ "top" $ do
        div ! id "word-cloud" $ do
          cloud
        div ! id "intro" $ do
          h1 "Learn Vocabulary—Fast"
          p $ do
            toMarkup $ "Learn foreign words with " ++ prettyPrint nLinkwords ++ " "
            a ! href "article/how-do-linkword-mnemonics-work" $ "linkword mnemonics"
            toMarkup $ " and " ++ prettyPrint nStories ++ " accompanying stories."
          p $ do
            "Retain the words through "
            a ! href "article/how-does-spaced-repetition-work" $ "spaced repetition"
            toMarkup $ " (" ++ prettyPrint nReviews ++ " reviews to-date)."
          p $ do
            toMarkup $ prettyPrint nEsLinks ++ " of the "
            a ! href "article/why-study-words-in-order-of-frequency" $ "most common"
            " Spanish words await you. More mnemonics and stories are being added weekly. The service is free."
          p ! id "try-now" $ do
            a ! href "/learn?learn=es&known=en" ! class_ "faint-gradient-button green" $ do
              "Get Started"
              br
              "with Spanish" ]

-- Generate a cloud of words from links in the database.

data WordStyle = WordStyle (Float, Float) (Float, Float) Int Int
  deriving (Show, Eq)

wordCloud :: [(String, Int32)] -> Int -> Int -> Int -> Int -> Int -> IO Html
wordCloud words width' height' fontMin fontMax numClasses = do
  gen <- getStdGen
  let (styles, (newGen, _)) = runState (mapM (wordStyle . fst) words) (gen, [])
  setStdGen newGen
  return $ mconcat $ catMaybes $ zipWith (\ w s -> liftM (wordTag w) s) words styles
 where wordTag :: (String, Int32) -> WordStyle -> Html
       wordTag (word, linkNo) (WordStyle (x, y) _ classNum fontSize) =
         let style' = "font-size: " ++ show fontSize ++ "px; "
                   ++ "left: " ++ show x ++ "%; " ++ "top: " ++ show y ++ "%;" in
         a ! href (toValue $ "/link/" ++ show linkNo)
           ! class_ (toValue $ "class-" ++ show classNum)
           ! style (toValue style')
           $ toMarkup word
       wordStyle :: String -> State (StdGen, [WordStyle]) (Maybe WordStyle)
       wordStyle word = do
         let fontRange = fontMax - fontMin
         fontSize <- (\ s -> fontMax - round (logBase 1.15 ((s * (1.15 ^ fontRange)::Float) + 1))) <$> getRandomR 0.0 1.0
         let widthP  = (100.0 / fromIntegral width')  * genericLength word * fromIntegral fontSize
             heightP = (100.0 / fromIntegral height') * fromIntegral fontSize
         x        <- getRandomR 0 (max (100 - widthP) 1)
         y        <- getRandomR 0 (max (100 - heightP) 1)
         class'   <- getRandomR 1 numClasses
         (gen, prev) <- get
         let spiral' = spiral 30.0 (x, y)
             styles  = filter inBounds $ map (\ pos -> WordStyle pos (widthP, heightP) class' fontSize) spiral'
             style'  = find (\ s -> not $ any (`overlap` s) prev) styles
         case style' of
           Nothing -> return Nothing
           Just style'' -> do
             put (gen, style'':prev)
             return $ Just style''
       getRandomR :: Random a => a -> a -> State (StdGen, [WordStyle]) a
       getRandomR min' max' = do
         (gen, styles) <- get
         let (n', newGen) = randomR (min', max') gen
         put (newGen, styles)
         return n'
       inBounds :: WordStyle -> Bool
       inBounds (WordStyle (x, y) (w, h) _ _) = x >= 0 && y >= 0 && x + w <= 100 && y + h <= 100
       overlap :: WordStyle -> WordStyle -> Bool
       -- We can't really be certain of when a word is overlapping,
       -- since the words will be rendered by the user's browser.
       -- However, we can make a guess.
       overlap (WordStyle (x1, y1) (w1', h1') _ _) (WordStyle (x2, y2) (w2', h2') _ _) =
         let hInter = (x2 > x1 && x2 < x1 + w1') || (x2 + w2' > x1 && x2 + w2' < x1 + w1') || (x2 < x1 && x2 + w2' > x1 + w1')
             vInter = (y2 > y1 && y2 < y1 + h1') || (y2 + h2' > y1 && y2 + h2' < y1 + h1') || (y2 < y1 && y2 + h2' > y1 + h1') in
         hInter && vInter
       spiral :: Float -> (Float, Float) -> [(Float, Float)]
       spiral maxTheta = spiral' 0.0
        where spiral' theta (x, y) =
                if theta > maxTheta
                  then []
                  else let r  = theta * 3
                           x' = (r * cos theta) + x
                           y' = (r * sin theta) + y in
                       (x', y') : spiral' (theta + 0.1) (x, y)
