{-# LANGUAGE OverloadedStrings, RecordWildCards, GADTs, CPP #-}
-- | PostgreSQL backend for Selda.
module Database.Selda.PostgreSQL
  ( PGConnectInfo (..)
  , withPostgreSQL, on, auth
  , pgOpen, pgOpen', seldaClose
  , pgConnString, pgPPConfig
  ) where
import qualified Data.ByteString.Char8 as BS
import Data.Dynamic
import Data.Foldable (for_)
import Data.Monoid
import qualified Data.Text as T
import Data.Text.Encoding
import Database.Selda.Backend
import Control.Monad (forM_, void)
import Control.Monad.Catch
import Control.Monad.IO.Class

#ifndef __HASTE__
import Database.Selda.PostgreSQL.Encoding
import Database.PostgreSQL.LibPQ hiding (user, pass, db, host)
#endif

-- | PostgreSQL connection information.
data PGConnectInfo = PGConnectInfo
  { -- | Host to connect to.
    pgHost     :: T.Text
    -- | Port to connect to.
  , pgPort     :: Int
    -- | Name of database to use.
  , pgDatabase :: T.Text
    -- | Schema to use upon connection.
  , pgSchema   :: Maybe T.Text
    -- | Username for authentication, if necessary.
  , pgUsername :: Maybe T.Text
    -- | Password for authentication, if necessary.
  , pgPassword :: Maybe T.Text
  }

-- | Connect to the given database on the given host, on the default PostgreSQL
--   port (5432):
--
-- > withPostgreSQL ("my_db" `on` "example.com") $ do
-- >   ...
on :: T.Text -> T.Text -> PGConnectInfo
on db host = PGConnectInfo
  { pgHost = host
  , pgPort = 5432
  , pgDatabase = db
  , pgSchema   = Nothing
  , pgUsername = Nothing
  , pgPassword = Nothing
  }
infixl 7 `on`

-- | Add the given username and password to the given connection information:
--
-- > withPostgreSQL ("my_db" `on` "example.com" `auth` ("user", "pass")) $ do
-- >   ...
--
--   For more precise control over the connection options, you should modify
--   the 'PGConnectInfo' directly.
auth :: PGConnectInfo -> (T.Text, T.Text) -> PGConnectInfo
auth ci (user, pass) = ci
  { pgUsername = Just user
  , pgPassword = Just pass
  }
infixl 4 `auth`

-- | Convert `PGConnectInfo` into `ByteString`
pgConnString :: PGConnectInfo -> BS.ByteString
#ifdef __HASTE__
pgConnString PGConnectInfo{..} = error "pgConnString called in JS context"
#else
pgConnString PGConnectInfo{..} = mconcat
  [ "host=", encodeUtf8 pgHost, " "
  , "port=", BS.pack (show pgPort), " "
  , "dbname=", encodeUtf8 pgDatabase, " "
  , case pgUsername of
      Just user -> "user=" <> encodeUtf8 user <> " "
      _         -> ""
  , case pgPassword of
      Just pass -> "password=" <> encodeUtf8 pass <> " "
      _         -> ""
  , "connect_timeout=10", " "
  , "client_encoding=UTF8"
  ]
#endif

-- | Perform the given computation over a PostgreSQL database.
--   The database connection is guaranteed to be closed when the computation
--   terminates.
withPostgreSQL :: (MonadIO m, MonadThrow m, MonadMask m)
               => PGConnectInfo -> SeldaT m a -> m a
#ifdef __HASTE__
withPostgreSQL _ _ = return $ error "withPostgreSQL called in JS context"
#else
withPostgreSQL ci m = bracket (pgOpen ci) seldaClose (runSeldaT m)
#endif

-- | Open a new PostgreSQL connection. The connection will persist across
--   calls to 'runSeldaT', and must be explicitly closed using 'seldaClose'
--   when no longer needed.
pgOpen :: (MonadIO m, MonadMask m) => PGConnectInfo -> m SeldaConnection
#ifdef __HASTE__
pgOpen _ = return $ error "pgOpen called in JS context"
#else
pgOpen ci = pgOpen' (pgSchema ci) (pgConnString ci)

pgOpen' :: (MonadIO m, MonadMask m) => Maybe T.Text -> BS.ByteString -> m SeldaConnection
pgOpen' schema connStr =
  bracketOnError (liftIO $ connectdb connStr) (liftIO . finish) $ \conn -> do
    st <- liftIO $ status conn
    case st of
      ConnectionOk -> do
        let backend = pgBackend conn

        _ <- liftIO $ runStmt backend "SET client_min_messages TO WARNING;" []

        for_ schema $ \schema' ->
          liftIO $ runStmt backend ("SET search_path TO '" <> schema' <> "';") []

        newConnection backend (decodeUtf8 connStr)
      nope -> do
        connFailed nope
    where
      connFailed f = throwM $ DbError $ unwords
        [ "unable to connect to postgres server: " ++ show f
        ]

pgPPConfig :: PPConfig
pgPPConfig = defPPConfig
    { ppType = pgColType defPPConfig
    , ppTypeHook = pgTypeHook
    , ppTypePK = pgColTypePK defPPConfig
    , ppAutoIncInsert = "DEFAULT"
    , ppColAttrs = T.unwords . map pgColAttr
    , ppColAttrsHook = pgColAttrsHook
    , ppIndexMethodHook = (" USING " <>) . compileIndexMethod
    }
  where
    compileIndexMethod BTreeIndex = "btree"
    compileIndexMethod HashIndex  = "hash"

    pgTypeHook :: SqlTypeRep -> [ColAttr] -> (SqlTypeRep -> T.Text) -> T.Text
    pgTypeHook ty attrs fun
      | isGenericIntPrimaryKey ty attrs = pgColTypePK pgPPConfig TRowID
      | otherwise = fun ty

    pgColAttrsHook :: SqlTypeRep -> [ColAttr] -> ([ColAttr] -> T.Text) -> T.Text
    pgColAttrsHook ty attrs fun
      | isGenericIntPrimaryKey ty attrs = fun [Primary]
      | otherwise = fun $ filter (/= AutoIncrement) attrs

    bigserialQue :: [ColAttr]
    bigserialQue = [Primary,AutoIncrement,Required,Unique]

    -- For when we use 'autoPrimaryGen' on 'Int' field
    isGenericIntPrimaryKey :: SqlTypeRep -> [ColAttr] -> Bool
    isGenericIntPrimaryKey ty attrs = ty == TInt && and ((`elem` attrs) <$> bigserialQue)

-- | Create a `SeldaBackend` for PostgreSQL `Connection`
pgBackend :: Connection   -- ^ PostgreSQL connection object.
          -> SeldaBackend
pgBackend c = SeldaBackend
  { runStmt         = \q ps -> right <$> pgQueryRunner c False q ps
  , runStmtWithPK   = \q ps -> left <$> pgQueryRunner c True q ps
  , prepareStmt     = pgPrepare c
  , runPrepared     = pgRun c
  , getTableInfo    = pgGetTableInfo c . rawTableName
  , backendId       = PostgreSQL
  , ppConfig        = pgPPConfig
  , closeConnection = \_ -> finish c
  , disableForeignKeys = disableFKs c
  }
  where
    left (Left x) = x
    left _        = error "impossible"
    right (Right x) = x
    right _         = error "impossible"

-- Solution to disable FKs from
-- <https://dba.stackexchange.com/questions/96961/how-to-temporarily-disable-foreign-keys-in-amazon-rds-postgresql>
disableFKs :: Connection -> Bool -> IO ()
disableFKs c True = do
    void $ pgQueryRunner c False "BEGIN TRANSACTION;" []
    void $ pgQueryRunner c False create []
    void $ pgQueryRunner c False drop []
  where
    create = mconcat
      [ "create table if not exists __selda_dropped_fks ("
      , "        seq bigserial primary key,"
      , "        sql text"
      , ");"
      ]
    drop = mconcat
      [ "do $$ declare t record;"
      , "begin"
      , "    for t in select conrelid::regclass::varchar table_name, conname constraint_name,"
      , "            pg_catalog.pg_get_constraintdef(r.oid, true) constraint_definition"
      , "            from pg_catalog.pg_constraint r"
      , "            where r.contype = 'f'"
      , "            and r.connamespace = (select n.oid from pg_namespace n where n.nspname = current_schema())"
      , "        loop"
      , "        insert into __selda_dropped_fks (sql) values ("
      , "            format('alter table if exists %s add constraint %s %s',"
      , "                quote_ident(t.table_name), quote_ident(t.constraint_name), t.constraint_definition));"
      , "        execute format('alter table %s drop constraint %s', quote_ident(t.table_name), quote_ident(t.constraint_name));"
      , "    end loop;"
      , "end $$;"
      ]
disableFKs c False = do
    void $ pgQueryRunner c False restore []
    void $ pgQueryRunner c False "DROP TABLE __selda_dropped_fks;" []
    void $ pgQueryRunner c False "COMMIT;" []
  where
    restore = mconcat
      [ "do $$ declare t record;"
      , "begin"
      , "    for t in select * from __selda_dropped_fks order by seq loop"
      , "        execute t.sql;"
      , "        delete from __selda_dropped_fks where seq = t.seq;"
      , "    end loop;"
      , "end $$;"
      ]

pgGetTableInfo :: Connection -> T.Text -> IO TableInfo
pgGetTableInfo c tbl = do
    Right (_, vals) <- pgQueryRunner c False tableinfo []
    if null vals
      then do
        pure $ TableInfo [] []
      else do
        Right pkInfo <- pgQueryRunner c False pkquery []
        let pk = case pkInfo of
              (_, [[SqlString pk]]) -> Just pk
              _                     -> Nothing
        Right (_, us) <- pgQueryRunner c False uniquequery []
        let uniques = map splitNames us
            loneUniques = [u | [u] <- uniques]
        Right (_, fks) <- pgQueryRunner c False fkquery []
        Right (_, ixs) <- pgQueryRunner c False ixquery []
        colInfos <- mapM (describe pk fks (map toText ixs) loneUniques) vals
        x <- pure $ TableInfo
          { tableColumnInfos = colInfos
          , tableUniqueGroups =
            [ map mkColName names
            | names@(_:_:_) <- uniques
            ]
          }
        pure x
  where
    splitNames [SqlString s] = breakNames s
    -- TODO: this is super ugly; should really be fixed
    breakNames s =
      case T.break (== '"') s of
        (n, ns) | T.null n  -> []
                | T.null ns -> [n]
                | otherwise -> n : breakNames (T.tail ns)
    toText [SqlString s] = s
    tableinfo = mconcat
      [ "SELECT column_name, data_type, is_nullable "
      , "FROM information_schema.columns "
      , "WHERE table_name = '", tbl, "';"
      ]
    pkquery = mconcat
      [ "SELECT a.attname "
      , "FROM pg_index i "
      , "JOIN pg_attribute a ON a.attrelid = i.indrelid "
      , "  AND a.attnum = ANY(i.indkey) "
      , "WHERE i.indrelid = '", tbl, "'::regclass "
      , "  AND i.indisprimary;"
      ]
    uniquequery = mconcat
      [ "SELECT string_agg(a.attname, '\"') "
      , "FROM pg_index i "
      , "JOIN pg_attribute a ON a.attrelid = i.indrelid "
      , "  AND a.attnum = ANY(i.indkey) "
      , "WHERE i.indrelid = '", tbl, "'::regclass "
      , "  AND i.indisunique "
      , "GROUP BY i.indkey;"
      ]
    fkquery = mconcat
      [ "SELECT kcu.column_name, ccu.table_name, ccu.column_name "
      , "FROM information_schema.table_constraints AS tc "
      , "JOIN information_schema.key_column_usage AS kcu "
      , "  ON tc.constraint_name = kcu.constraint_name "
      , "JOIN information_schema.constraint_column_usage AS ccu "
      , "  ON ccu.constraint_name = tc.constraint_name "
      , "WHERE constraint_type = 'FOREIGN KEY' AND tc.table_name='", tbl, "';"
      ]
    ixquery = mconcat
      [ "select a.attname as column_name "
      , "from pg_class t, pg_class i, pg_index ix, pg_attribute a "
      , "where "
      , "t.oid = ix.indrelid "
      , "and i.oid = ix.indexrelid "
      , "and a.attrelid = t.oid "
      , "and a.attnum = ANY(ix.indkey) "
      , "and t.relkind = 'r' "
      , "and t.relname = '", tbl , "';"
      ]
    describe pk fks ixs us [SqlString name, SqlString ty, SqlString nullable] =
      return $ ColumnInfo
        { colName = mkColName name
        , colType = mkTypeRep (pk == Just name) ty'
        , colIsPK = pk == Just name
        , colIsAutoIncrement = ty' == "bigserial"
        , colIsUnique = name `elem` us
        , colIsNullable = readBool (encodeUtf8 (T.toLower nullable))
        , colHasIndex = name `elem` ixs
        , colFKs =
            [ (mkTableName tbl, mkColName col)
            | [SqlString cname, SqlString tbl, SqlString col] <- fks
            , name == cname
            ]
        }
      where ty' = T.toLower ty
    describe _ _ _ _ results =
      throwM $ SqlError $ "bad result from table info query: " ++ show results

pgQueryRunner :: Connection -> Bool -> T.Text -> [Param] -> IO (Either Int (Int, [[SqlValue]]))
pgQueryRunner c return_lastid q ps = do
    mres <- execParams c (encodeUtf8 q') [fromSqlValue p | Param p <- ps] Text
    unlessError c errmsg mres $ \res -> do
      if return_lastid
        then Left <$> getLastId res
        else Right <$> getRows res
  where
    errmsg = "error executing query `" ++ T.unpack q' ++ "'"
    q' | return_lastid = q <> " RETURNING LASTVAL();"
       | otherwise     = q

    getLastId res = (readInt . maybe "0" id) <$> getvalue res 0 0

pgRun :: Connection -> Dynamic -> [Param] -> IO (Int, [[SqlValue]])
pgRun c hdl ps = do
    let Just sid = fromDynamic hdl :: Maybe StmtID
    mres <- execPrepared c (BS.pack $ show sid) (map mkParam ps) Text
    unlessError c errmsg mres $ getRows
  where
    errmsg = "error executing prepared statement"
    mkParam (Param p) = case fromSqlValue p of
      Just (_, val, fmt) -> Just (val, fmt)
      Nothing            -> Nothing

-- | Get all rows from a result.
getRows :: Result -> IO (Int, [[SqlValue]])
getRows res = do
  rows <- ntuples res
  cols <- nfields res
  types <- mapM (ftype res) [0..cols-1]
  affected <- cmdTuples res
  result <- mapM (getRow res types cols) [0..rows-1]
  pure $ case affected of
    Just "" -> (0, result)
    Just s  -> (readInt s, result)
    _       -> (0, result)

-- | Get all columns for the given row.
getRow :: Result -> [Oid] -> Column -> Row -> IO [SqlValue]
getRow res types cols row = do
  sequence $ zipWith (getCol res row) [0..cols-1] types

-- | Get the given column.
getCol :: Result -> Row -> Column -> Oid -> IO SqlValue
getCol res row col t = do
  mval <- getvalue res row col
  case mval of
    Just val -> pure $ toSqlValue t val
    _        -> pure SqlNull

pgPrepare :: Connection -> StmtID -> [SqlTypeRep] -> T.Text -> IO Dynamic
pgPrepare c sid types q = do
    mres <- prepare c (BS.pack $ show sid) (encodeUtf8 q) (Just types')
    unlessError c errmsg mres $ \_ -> return (toDyn sid)
  where
    types' = map fromSqlType types
    errmsg = "error preparing query `" ++ T.unpack q ++ "'"

-- | Perform the given computation unless an error occurred previously.
unlessError :: Connection -> String -> Maybe Result -> (Result -> IO a) -> IO a
unlessError c msg mres m = do
  case mres of
    Just res -> do
      st <- resultStatus res
      case st of
        BadResponse   -> doError c msg
        FatalError    -> doError c msg
        NonfatalError -> doError c msg
        _             -> m res
    Nothing -> throwM $ DbError "unable to submit query to server"

doError :: Connection -> String -> IO a
doError c msg = do
  me <- errorMessage c
  throwM $ SqlError $ concat
    [ msg
    , maybe "" ((": " ++) . BS.unpack) me
    ]

mkTypeRep :: Bool -> T.Text ->  Either T.Text SqlTypeRep
mkTypeRep True  "bigint"           = Right TRowID
mkTypeRep True  "bigserial"        = Right TRowID
mkTypeRep True  "int8"             = Right TRowID
mkTypeRep _ispk "int8"             = Right TInt
mkTypeRep _ispk "bigint"           = Right TInt
mkTypeRep _ispk "float8"           = Right TFloat
mkTypeRep _ispk "double precision" = Right TFloat
mkTypeRep _ispk "timestamp"        = Right TDateTime
mkTypeRep _ispk "timestamp without time zone" = Right TDateTime
mkTypeRep _ispk "bytea"            = Right TBlob
mkTypeRep _ispk "text"             = Right TText
mkTypeRep _ispk "boolean"          = Right TBool
mkTypeRep _ispk "date"             = Right TDate
mkTypeRep _ispk "time"             = Right TTime
mkTypeRep _ispk typ                = Left typ

-- | Custom column types for postgres.
pgColType :: PPConfig -> SqlTypeRep -> T.Text
pgColType _ TRowID    = "BIGINT"
pgColType _ TInt      = "INT8"
pgColType _ TFloat    = "FLOAT8"
pgColType _ TDateTime = "TIMESTAMP"
pgColType _ TBlob     = "BYTEA"
pgColType cfg t       = ppType cfg t

-- | Custom attribute types for postgres.
pgColAttr :: ColAttr -> T.Text
pgColAttr Primary       = "PRIMARY KEY"
pgColAttr AutoIncrement = ""
pgColAttr Required      = "NOT NULL"
pgColAttr Optional      = "NULL"
pgColAttr Unique        = "UNIQUE"
pgColAttr (Indexed _)   = ""

-- | Custom column types (primary key position) for postgres.
pgColTypePK :: PPConfig -> SqlTypeRep -> T.Text
pgColTypePK _ TRowID    = "BIGSERIAL"
pgColTypePK cfg t       = pgColType cfg t
#endif
