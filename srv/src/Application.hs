{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{-|

Top-level application with AuthManager, Redson and utility handlers.
Serve index page, check user login.

-}

module Application (appInit)

where

import Prelude hiding (catch, lookup)

import qualified Data.Aeson as A

import Control.Monad.IO.Class
import Data.Functor
import Data.Maybe

import Data.ByteString (ByteString)
import Data.Configurator
import Data.Lens.Template
import Data.Time.Clock

import Snap.Core
import Snap.Snaplet
import Snap.Snaplet.Auth hiding (session)
import Snap.Snaplet.Auth.Backends.JsonFile
import Snap.Snaplet.Heist
import Snap.Snaplet.Session
import Snap.Snaplet.Session.Backends.CookieSession
import Snap.Util.FileServe
import Snap.Util.FileUploads

import Snap.Snaplet.Redson

import System.Directory (getTemporaryDirectory)
import System.Posix.Files (createLink, removeLink)

import Control.Concurrent
import Control.Exception (SomeException)
import Control.Monad.CatchIO (finally, catch, try)

import Vin.Import


------------------------------------------------------------------------------
-- | Application snaplet state type: Redson, Heist.
data App = App
    { _heist :: Snaplet (Heist App)
    , _redson :: Snaplet (Redson App)
    , _session :: Snaplet SessionManager
    , _auth :: Snaplet (AuthManager App)
    , _startTime :: UTCTime
    }

type AppHandler = Handler App App

makeLens ''App

instance HasHeist App where
    heistLens = subSnaplet heist


------------------------------------------------------------------------------
-- | Render empty form for model.
indexPage :: AppHandler ()
indexPage = ifTop $ render "index"


------------------------------------------------------------------------------
-- | Redirect using 303 See Other to login form.
--
-- Used after unsuccessful access/login attempt or logout.
redirectToLogin :: MonadSnap m => m a
redirectToLogin = redirect' "/login/" 303


------------------------------------------------------------------------------
-- | If user is not logged in, redirect to login page, pass to
-- handler otherwise.
authOrLogin :: AppHandler () -> AppHandler ()
authOrLogin h = requireUser auth redirectToLogin h


------------------------------------------------------------------------------
-- | Render empty login form.
loginForm :: AppHandler ()
loginForm = do
  serveFile $ "snaplets/heist/resources/templates/login.html"


------------------------------------------------------------------------------
-- | Login user.
doLogin :: AppHandler ()
doLogin = ifTop $ do
  l <- fromMaybe "" <$> getParam "login"
  p <- fromMaybe "" <$> getParam "password"
  r <- maybe False (const True) <$> getParam "remember"
  res <- with auth $ loginByUsername l (ClearText p) r
  case res of
    Left err -> redirectToLogin
    Right user -> redirect "/"

------------------------------------------------------------------------------
-- | Serve user account data back to client.
--
-- Assume that user login is already checked with 'authOrLogin'.
serveUserCake :: AppHandler ()
serveUserCake = ifTop $ do
  Just user <- with auth $ currentUser
  modifyResponse $ setContentType "application/json"
  writeLBS $ A.encode user


------------------------------------------------------------------------------
-- | Upload file with VIN numbers.
doVin :: AppHandler ()
doVin = ifTop $ do
  d <- liftIO $ getTemporaryDirectory

  handleFileUploads d defaultUploadPolicy partUploadPolicy handler
    `catch` (writeText . fileUploadExceptionReason)

  where
    partUploadPolicy _ = allowWithMaximumSize $ 100 * 2^(20::Int)

    handler []        = writeBS "no files"
    handler ((info,f):_) = do
        program <- fromMaybe "" <$> getParam "program"

        either (writeText . policyViolationExceptionReason)
               (action program $ partContentType info)
               f


action :: ByteString -> ByteString -> FilePath -> AppHandler ()
action program contentType f = do
  liftIO $ createLink f f'

  liftIO $ forkIO $ do
      res <- try $ loadFile f' fError program contentType

      case res of
        Left  e -> print (e :: SomeException)
        Right r -> either print print r

      `finally` removeLink f'

  writeBS "Ok"
  where
    fError = "resources/static/error.csv"
    f' = f ++ "-link"

------------------------------------------------------------------------------
-- | The application's routes.
routes :: [(ByteString, AppHandler ())]
routes = [ ("/", method GET $ authOrLogin indexPage)
         , ("/login/", method GET loginForm)
         , ("/login/", method POST doLogin)
         , ("/logout/", with auth $ logout >> redirectToLogin)
         , ("/vin", method POST doVin)
         , ("/_whoami/", method GET $ authOrLogin serveUserCake)
         , ("/s/", serveDirectory "resources/static")
         ]


sessionTimeout :: Maybe Int
sessionTimeout = Nothing


------------------------------------------------------------------------------
-- | The application initializer.
appInit :: SnapletInit App App
appInit = makeSnaplet "app" "Forms application" Nothing $ do
  r <- nestSnaplet "_" redson $ redsonInit auth

  h <- nestSnaplet "heist" heist $ heistInit "resources/templates"
  addAuthSplices auth

  cfg <- getSnapletUserConfig
  sesKey <- liftIO $
            lookupDefault "resources/private/client_session_key.aes"
                          cfg "session-key"
  rmbKey <- liftIO $
            lookupDefault "resources/private/site_key.txt"
                          cfg "remember-key"
  rmbPer <- liftIO $
            lookupDefault 14 
                          cfg "remember-period"
  authDb <- liftIO $
            lookupDefault "resources/private/users.json"
                          cfg "user-db"

  s <- nestSnaplet "session" session $
       initCookieSessionManager sesKey "_session" sessionTimeout
  a <- nestSnaplet "auth" auth $
       initJsonFileAuthManager
       defAuthSettings{ asSiteKey = rmbKey
                      , asRememberPeriod = Just (rmbPer * 24 * 60 * 60)}
                               session authDb

  sTime <- liftIO getCurrentTime

  addRoutes routes

  return $ App h r s a sTime
