import os
import pymysql
from dbutils.pooled_db import PooledDB
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

_pool = None


def _create_pool():
    global _pool
    if _pool is None:
        _pool = PooledDB(
            creator=pymysql,
            mincached=2,
            maxcached=5,
            maxconnections=10,
            blocking=True,
            host=os.getenv("MYSQL_HOST", "localhost"),
            user=os.getenv("MYSQL_USER", "root"),
            password=os.getenv("MYSQL_PASSWORD"),
            database=os.getenv("MYSQL_DATABASE", "campus_delivery_db"),
            charset=os.getenv("MYSQL_CHARSET", "utf8mb4"),
            cursorclass=pymysql.cursors.Cursor,
        )
    return _pool


def get_connection():
    return _create_pool().connection()


def close_pool():
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


def check_connection():
    """快速检查数据库是否可达，返回 (ok, message)"""
    try:
        conn = get_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
        return True, "数据库连接正常"
    except Exception as e:
        return False, str(e)
