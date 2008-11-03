> module Vocabulink.Member where

> import Vocabulink.CGI
> import Vocabulink.DB
> import Vocabulink.Html
> import Vocabulink.Utils

> import Control.Monad
> import Data.ByteString.Char8 (pack)
> import Data.Digest.OpenSSL.HMAC
> import Data.Maybe
> import Data.List
> import Data.Time.Clock.POSIX
> import Database.HDBC
> import Network.CGI
> import System.IO
> import Text.ParserCombinators.Parsec hiding (label)
> import Text.XHtml.Strict

Add a member to the database. We're going to do validation of acceptable
username characters at this level because PostgreSQL's CHECK constraint doesn't
handle Unicode regular expressions properly.

A username should be allowed to have any alphanumeric characters (in any
language) and URL-safe punctuation.

> addMember :: IConnection conn => conn -> String -> String -> Maybe String -> IO ()
> addMember c username passwd email =
>     (length username) < 3  ? error "Your username must have 3 characters or more."  $
>     (length username) > 32 ? error "Your username must have 32 characters or less." $
>     (length passwd)   > 72 ? error "Your password must have 72 characters or less." $
>     -- TODO: Add password constraints?
>     quickInsert c "INSERT INTO member (username, email, password_hash) \
>                   \VALUES (?, ?, crypt(?, gen_salt('bf')))"
>                   [toSql' username, toSql' email, toSql' passwd]
>       `catchSqlE` "Failed to add member."

> addMember' :: CGI CGIResult
> addMember' = do
>   c <- liftIO db
>   username <- getInput' "username"
>   passwd   <- getInput' "password"
>   email    <- getInput' "email"
>   liftIO $ addMember c username passwd email
>   output $ "Welcome!"

> newMemberPage :: String
> newMemberPage = renderHtml $ page "Join Vocabulink" []
>   [ h1 << "Join Vocabulink",
>     form ! [action "", method "post"] <<|
>       [ label << "Username:",
>         input ! [name "username", thetype "text"],
>         br,
>         label << "Password:",
>         input ! [name "password", thetype "password"],
>         br,
>         label << "Email:",
>         input ! [name "email", thetype "text"],
>         br,
>         input ! [thetype "submit", value "Join"]]]

> memberNumber :: IConnection conn => conn -> String -> IO (Integer)
> memberNumber c username =
>   fromSql `liftM` query1e c "SELECT member_no FROM member \
>                             \WHERE username = ?" [toSql' username]
>     `catchSqlE` "Failed to retrieve member number from username."

> memberName :: IConnection conn => conn -> Integer -> IO (String)
> memberName c memberNo =
>   fromSql' `liftM` query1e c "SELECT username FROM member \
>                              \WHERE member_no = ?" [toSql memberNo]
>     `catchSqlE` "Failed to retrieve username from member number."

Login attempts to match the username and password supplied against the
information in the database.

> validPassword :: IConnection conn => conn -> String -> String -> IO (Bool)
> validPassword c username passwd =
>   fromSql `liftM` query1e c "SELECT password_hash = crypt(?, password_hash) \
>                             \FROM member WHERE username = ?"
>                             [toSql' passwd, toSql' username]
>     `catchSqlE` "Internal authentication failure (this is not your fault)."

Each time a user logs in, we send an authentication cookie to their browser.
The cookie is an digest of some state information we store in our database
(expiration time, IP address). We then use the cookie for authenticating their
identity on subsequent requests.

We don't want to store information like IP address for a user. All of the
session state stays in the cookie. This also keeps us from having to deal with
storing session state on our end.

> data AuthToken = AuthToken {
>   expiry    :: POSIXTime,
>   member    :: Integer,
>   ipAddress :: String,
>   digest    :: String
> }

> instance Show AuthToken where
>     show a = "exp=" ++ (show (floor (expiry a) :: Integer)) ++ "&no=" ++ (show (member a)) ++
>              "&ip=" ++ (ipAddress a) ++ "&mac=" ++ (digest a)

This really needs some cleanup.

> authTokenParser :: Parser AuthToken
> authTokenParser = do
>   string "exp="
>   seconds <- manyTill anyChar $ char '&'
>   string "no="
>   member_no <- manyTill anyChar $ char '&'
>   string "ip="
>   ip <- manyTill anyChar $ char '&'
>   string "mac="
>   digest' <- many1 anyChar
>   return AuthToken { expiry    = fromInteger (read seconds) :: POSIXTime,
>                      member    = read member_no,
>                      ipAddress = ip,
>                      digest    = digest' }

> parseAuthToken :: String -> Maybe AuthToken
> parseAuthToken s = case parse authTokenParser "" s of
>                    Left e  -> error (show e)
>                    Right x -> Just x

Create an AuthToken with the default expiration time, automatically calculating
the digest.

> authToken :: Integer -> String -> IO (AuthToken)
> authToken member_no ip = do
>   utc <- getPOSIXTime
>   let expires = utc + posixDayLength
>   -- TODO: Use a proper key.
>   digest' <- digestToken $ AuthToken { expiry    = expires,
>                                        member    = member_no,
>                                        ipAddress = ip,
>                                        digest    = "" }
>   return AuthToken { expiry    = expires,
>                      member    = member_no,
>                      ipAddress = ip,
>                      digest    = digest' }

Eventually, we need to rotate the key used to generate the HMAC, while still
storing old keys long enough to use them for any valid login session. Without
this, authentication is less secure.

> digestToken :: AuthToken -> IO (String)
> digestToken a = hmac sha1 (pack "blahblahblah")
>                      (pack $ (show (floor (expiry a) :: Integer)) ++ (show (member a)) ++ (ipAddress a))

> verifyTokenDigest :: AuthToken -> IO (Bool)
> verifyTokenDigest a = do
>   digest' <- digestToken a
>   return ((digest a) == digest')

Returns the member number or Nothing if the cookie is invalid or expired.

> verifyMember :: String -> String -> IO (Maybe Integer)
> verifyMember cookie ip =
>   case parseAuthToken cookie of
>     Nothing -> return Nothing
>     Just a  -> do
>       utc <- getPOSIXTime
>       valid <- verifyTokenDigest a
>       if valid && ip == (ipAddress a) && (not $ expired utc (expiry a))
>          then return (Just (member a))
>          else return Nothing

> expired :: POSIXTime -> POSIXTime -> Bool
> expired now ex = (floor ex :: Integer) - (floor now :: Integer) < 0

> loginNumber :: CGI (Integer)
> loginNumber = do
>   authCookie <- getCookie "auth"
>   case authCookie of
>     Nothing -> return 0
>     Just c  -> do
>       ip <- remoteAddr
>       memberNo <- liftIO $ verifyMember c ip
>       case memberNo of
>         Nothing -> return 0 -- anonymous
>         Just n  -> return n

> loginName :: CGI (String)
> loginName = do
>   c <- liftIO db
>   n <- loginNumber
>   liftIO $ memberName c n >>= return

> loggedIn :: CGI (Bool)
> loggedIn = do
>   n <- loginNumber
>   return $ n > 0

If we want to set the expiration, we have to muck around with CalendarTimes and
use something like
  addToClockTime TimeDiff { tdYear = 0,
                            tdMonth = 0,
                            tdDay = 1,
                            tdHour = 0,
                            tdMin = 0,
                            tdSec = 0,
                            tdPicosec = 0 }

For now, I'm just going to let it expire at the end of the session. If the
session lasts longer than the expiration time, we can invalidate the cookie.

> login' :: CGI CGIResult
> login' = do
>   c <- liftIO db
>   username  <- getInput' "username"
>   member_no <- liftIO $ memberNumber c username
>   passwd    <- getInput' "password"
>   referer'  <- getInputDefault "referer" "/"
>   ip <- remoteAddr
>   valid <- liftIO $ validPassword c username passwd
>   not valid ? error "Login failed." $ do
>       authTok <- liftIO $ authToken member_no ip
>       setCookie Cookie { cookieName    = "auth",
>                          cookieValue   = (show authTok),
>                          cookieExpires = Nothing,
>                          cookieDomain  = Just "vocabulink.com",
>                          cookiePath    = Just "/",
>                          cookieSecure  = False }
>       redirect referer'

> loginPage :: CGI CGIResult
> loginPage = do
>   referer' <- referer
>   output $ renderHtml $ page "Log In" []
>     [ h1 << "Log In",
>       form ! [action "", method "post"] <<|
>         [ input ! [name "referer", thetype "hidden", value referer'],
>           label << "Username:",
>           input ! [name "username", thetype "text"],
>           br,
>           label << "Password:",
>           input ! [name "password", thetype "password"],
>           br,
>           input ! [thetype "submit", value "Log In"]],
>       paragraph << ("Not a member? " +++ anchor ! [href "/member/join"] << "Join!") ]