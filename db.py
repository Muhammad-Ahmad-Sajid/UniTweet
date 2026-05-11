import psycopg2
from psycopg2.pool import SimpleConnectionPool
import firebase

db_config = {
    "host": "localhost",
    "port": 5432,
    "database": "uni_social_db",
    "user": "postgres",
    "password": "MohsinSajid@@"
}

_pool = None

def get_pool():
    """Lazily initialize and return a reusable connection pool."""
    global _pool
    if _pool is None:
        _pool = SimpleConnectionPool(1, 10, **db_config)
    return _pool

def get_connection():
    """Returns a pooled psycopg2 connection."""
    return get_pool().getconn()

def execute_query(sql, params=None, fetch="all"):
    """Executes a query, manages connection lifecycle, and returns dictated structures safely."""
    conn = None
    try:
        conn = get_connection()
        with conn.cursor() as cur:
            cur.execute(sql, params)
            
            if fetch == "none":
                conn.commit()
                return True
                
            result = None
            if cur.description:
                columns = [desc[0] for desc in cur.description]
                if fetch == "one":
                    row = cur.fetchone()
                    result = dict(zip(columns, row)) if row else None
                elif fetch == "all":
                    rows = cur.fetchall()
                    result = [dict(zip(columns, row)) for row in rows]
            else:
                result = None if fetch == "one" else []
                
            conn.commit()
            return result
    except Exception as e:
        print(f"Database error in execute_query while running {sql}: {e}")
        if fetch == "none": return False
        if fetch == "one": return None
        return []
    finally:
        if conn:
            get_pool().putconn(conn)

def register_user(reg_no, full_name, email, password_hash, batch_year, department):
    """Registers a new user in the database."""
    res = execute_query("SELECT * FROM register_user(%s, %s, %s, %s, %s, %s)", 
                         (reg_no, full_name, email, password_hash, batch_year, department), fetch="none")
    if res:
        firebase.sync_user_to_firebase({
            'reg_no': reg_no,
            'full_name': full_name,
            'email': email,
            'password_hash': password_hash,
            'batch_year': batch_year,
            'department': department
        })
    return res

def get_user_for_login(identifier):
    """Retrieves user credentials by email or reg_no."""
    return execute_query("SELECT * FROM get_user_for_login(%s)", (identifier,), fetch="one")

def get_user_profile(target_user_id, caller_user_id):
    """Retrieves full profile stats for a specific user."""
    return execute_query("SELECT * FROM get_user_profile(%s, %s)", (target_user_id, caller_user_id), fetch="one")

def create_tweet(user_id, content):
    """Creates a new tweet authored by the user."""
    res = execute_query("SELECT * FROM create_tweet(%s, %s)", (user_id, content), fetch="one")
    if res and 'create_tweet' in res:
        firebase.sync_tweet_to_firebase({
            'tweet_id': res['create_tweet'],
            'author_reg_no': user_id,
            'content': content,
            'is_deleted': False,
            'like_count': 0,
            'reply_count': 0
        })
    return res

def delete_tweet(tweet_id, user_id):
    """Soft deletes a tweet authored by the user."""
    res = execute_query("SELECT * FROM delete_tweet(%s, %s)", (tweet_id, user_id), fetch="none")
    if res:
        firebase.delete_tweet_from_firebase(tweet_id)
        firebase.delete_tweet_image_from_firebase(tweet_id)
    return res

def get_tweet_by_id(tweet_id):
    """Gets detailed view of a single tweet."""
    return execute_query("SELECT * FROM get_tweet_by_id(%s)", (tweet_id,), fetch="one")

def get_home_feed(user_id, offset_n=0, fetch_n=20):
    """Retrieves timeline of tweets from followed users."""
    return execute_query("SELECT * FROM get_home_feed(%s, %s, %s)", (user_id, offset_n, fetch_n), fetch="all")

def get_trending_feed(offset_n=0, fetch_n=20):
    """Retrieves top liked tweets from the last 7 days."""
    return execute_query("SELECT * FROM get_trending_feed(%s, %s)", (offset_n, fetch_n), fetch="all")

def get_user_tweets(user_id, offset_n=0, fetch_n=20):
    """Retrieves tweets authored by a specific user."""
    return execute_query("SELECT * FROM get_user_tweets(%s, %s, %s)", (user_id, offset_n, fetch_n), fetch="all")

def toggle_like(tweet_id, user_id):
    """Toggles like status on a tweet."""
    res = execute_query("SELECT * FROM toggle_like(%s, %s)", (tweet_id, user_id), fetch="one")
    is_liked = res['toggle_like'] if res and 'toggle_like' in res else False
    if res:
        if is_liked:
            firebase.sync_like_to_firebase({'tweet_id': tweet_id, 'user_reg_no': user_id})
        else:
            db = firebase.get_db()
            if db:
                db.collection('likes').document(f"{tweet_id}_{user_id}").delete()
    return is_liked

def add_reply(tweet_id, user_id, parent_reply_id, content):
    """Posts a reply to a tweet or an existing comment."""
    res = execute_query("SELECT * FROM add_reply(%s, %s, %s, %s)", (tweet_id, user_id, parent_reply_id, content), fetch="one")
    if res and 'add_reply' in res:
        firebase.sync_reply_to_firebase({
            'reply_id': res['add_reply'],
            'tweet_id': tweet_id,
            'author_reg_no': user_id,
            'parent_reply_id': parent_reply_id,
            'content': content,
            'is_deleted': False
        })
    return res

def get_replies(tweet_id):
    """Retrieves threaded replies for a tweet."""
    return execute_query("SELECT * FROM get_replies(%s)", (tweet_id,), fetch="all")

def toggle_follow(source_user_id, target_user_id):
    """Toggles follow status between two users."""
    res = execute_query("SELECT * FROM toggle_follow(%s, %s)", (source_user_id, target_user_id), fetch="one")
    is_following = res['toggle_follow'] if res and 'toggle_follow' in res else False
    if res:
        if is_following:
            firebase.sync_follow_to_firebase(source_user_id, target_user_id)
        else:
            db = firebase.get_db()
            if db:
                db.collection('follows').document(f"{source_user_id}_{target_user_id}").delete()
    return is_following

def get_followers(user_id):
    """Lists users who follow the given user."""
    return execute_query("SELECT * FROM get_followers(%s)", (user_id,), fetch="all")

def get_following(user_id):
    """Lists users that the given user follows."""
    return execute_query("SELECT * FROM get_following(%s)", (user_id,), fetch="all")

def send_message(sender_id, receiver_id, content):
    """Sends a direct message."""
    res = execute_query("SELECT * FROM send_message(%s, %s, %s)", (sender_id, receiver_id, content), fetch="one")
    if res and 'send_message' in res:
        firebase.sync_message_to_firebase({
            'message_id': res['send_message'],
            'sender_reg_no': sender_id,
            'receiver_reg_no': receiver_id,
            'content': content,
            'is_deleted': False
        })
    return res

def get_conversation(user_a, user_b, offset_n=0, fetch_n=50):
    """Retrieves message history between two users."""
    return execute_query("SELECT * FROM get_conversation(%s, %s, %s, %s)", (user_a, user_b, offset_n, fetch_n), fetch="all")

def get_inbox(user_id):
    """Retrieves list of latest messages per conversation."""
    return execute_query("SELECT * FROM get_inbox(%s)", (user_id,), fetch="all")

def search_users(query):
    """Searches users by full name, reg_no, or department."""
    return execute_query("SELECT * FROM search_users(%s)", (query,), fetch="all")

def search_tweets(query):
    """Performs full text search over tweet content."""
    return execute_query("SELECT * FROM search_tweets(%s)", (query,), fetch="all")

def get_pending_reports(offset_n=0, fetch_n=50):
    """Lists all unresolved moderation reports."""
    return execute_query("SELECT * FROM get_pending_reports(%s, %s)", (offset_n, fetch_n), fetch="all")

def resolve_report_delete(report_id, admin_id):
    """Resolves report and soft deletes target tweet."""
    res = execute_query("SELECT * FROM resolve_report_delete(%s, %s)", (report_id, admin_id), fetch="none")
    if res:
        db = firebase.get_db()
        if db:
            db.collection('reports').document(str(report_id)).update({'status': 'RESOLVED'})
    return res

def resolve_report_dismiss(report_id, admin_id):
    """Dismisses moderation report safely."""
    res = execute_query("SELECT * FROM resolve_report_dismiss(%s, %s)", (report_id, admin_id), fetch="none")
    if res:
        db = firebase.get_db()
        if db:
            db.collection('reports').document(str(report_id)).update({'status': 'DISMISSED'})
    return res

def create_report(reporter_id, target_type, target_id, reason):
    """Submits a new moderation report."""
    res = execute_query("SELECT * FROM create_report(%s, %s, %s, %s)", (reporter_id, target_type, target_id, reason), fetch="none")
    if res:
        report_dict = {
            'reporter_reg_no': reporter_id,
            'reason': reason,
            'status': 'PENDING'
        }
        if target_type == 'TWEET':
            report_dict['reported_tweet_id'] = target_id
            report_dict['reported_user_reg_no'] = None
        else:
            report_dict['reported_tweet_id'] = None
            report_dict['reported_user_reg_no'] = target_id
            
        # Try to use a composite ID for the report, or let Firestore auto-generate it if report_id isn't returned
        firebase.sync_report_to_firebase(report_dict)
    return res

def generate_user_report(user_id):
    """Computes comprehensive activity totals for a user."""
    return execute_query("SELECT * FROM generate_user_report(%s)", (user_id,), fetch="one")

def admin_bulk_dismiss(days_old, admin_id):
    """Dismisses old reports automatically."""
    return execute_query("SELECT * FROM admin_bulk_dismiss(%s, %s)", (days_old, admin_id), fetch="one")

def build_home_digest(user_id):
    """Creates a text digest of latest timeline tweets."""
    return execute_query("SELECT * FROM build_home_digest(%s)", (user_id,), fetch="one")

def upload_avatar(user_id, image_bytes, filename):
    """Uploads user profile picture to both Postgres and Firebase."""
    res = execute_query("SELECT * FROM upload_avatar(%s, %s, %s)", (user_id, psycopg2.Binary(image_bytes), filename), fetch="none")
    if res:
        firebase.upload_avatar_to_firebase(user_id, image_bytes, filename)
    return res

def get_avatar(user_id):
    """Fetches user profile picture from Postgres."""
    return execute_query("SELECT * FROM get_avatar(%s)", (user_id,), fetch="one")

def create_tweet_with_image(user_id, content, image_bytes, filename):
    """Creates a new tweet with an attached image in both Postgres and Firebase."""
    res = execute_query("SELECT * FROM create_tweet_with_image(%s, %s, %s, %s)", 
                        (user_id, content, psycopg2.Binary(image_bytes), filename), fetch="one")
    if res and 'create_tweet_with_image' in res:
        tweet_id = res['create_tweet_with_image']
        # Sync the tweet text part
        firebase.sync_tweet_to_firebase({
            'tweet_id': tweet_id,
            'author_reg_no': user_id,
            'content': content,
            'is_deleted': False,
            'like_count': 0,
            'reply_count': 0
        })
        # Sync the image part
        firebase.upload_tweet_image_to_firebase(tweet_id, user_id, image_bytes, filename)
    return res

def get_tweet_image(tweet_id):
    """Fetches tweet image from Postgres."""
    return execute_query("SELECT * FROM get_tweet_image(%s)", (tweet_id,), fetch="one")
