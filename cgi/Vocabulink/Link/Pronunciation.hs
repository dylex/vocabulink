-- Copyright 2011, 2012 Chris Forno

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

module Vocabulink.Link.Pronunciation (pronounceable) where

import Vocabulink.App
import Vocabulink.Utils

import Prelude hiding (writeFile)

pronounceable :: Integer -> App Bool
pronounceable linkNo = do
  f <- pronunciationFile linkNo "ogg"
  liftIO $ isFileReadable f

pronunciationFile :: Integer -> String -> App FilePath
pronunciationFile linkNo filetype = do
  -- This pronunciation has not technically been uploaded, but we'll keep it
  -- the upload directory for now.
  dir <- (</> "upload" </> "audio" </> "pronunciation") <$> asks appDir
  return $ dir </> show linkNo <.> filetype
