import psycopg2

db_config = {
    "host": "localhost",
    "port": 5432,
    "database": "uni_social_db",
    "user": "postgres",
    "password": "MohsinSajid@@"
}

def get_connection():
    """Returns a new psycopg2 connection using db_config."""
    return psycopg2.connect(**db_config)

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
            conn.close()

def register_user(reg_no, full_name, email, password_hash, batch_year, department):
    """Registers a new user in the database."""
    return execute_query("SELECT * FROM register_user(%s, %s, %s, %s, %s, %s)", 
                         (reg_no, full_name, email, password_hash, batch_year, department), fetch="none")

def get_user_for_login(identifier):
    """Retrieves user credentials by email or reg_no."""
    return execute_query("SELECT * FROM get_user_for_login(%s)", (identifier,), fetch="one")

def get_user_profile(target_user_id, caller_user_id):
    """Retrieves full profile stats for a specific user."""
    return execute_query("SELECT * FROM get_user_profile(%s, %s)", (target_user_id, caller_user_id), fetch="one")

def create_tweet(user_id, content):
    """Creates a new tweet authored by the user."""
    return execute_query("SELECT * FROM create_tweet(%s, %s)", (user_id, content), fetch="one")

def delete_tweet(tweet_id, user_id):
    """Soft deletes a tweet authored by the user."""
    return execute_query("SELECT * FROM delete_tweet(%s, %s)", (tweet_id, user_id), fetch="none")

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
    return res['toggle_like'] if res and 'toggle_like' in res else False

def add_reply(tweet_id, user_id, parent_reply_id, content):
    """Posts a reply to a tweet or an existing comment."""
    return execute_query("SELECT * FROM add_reply(%s, %s, %s, %s)", (tweet_id, user_id, parent_reply_id, content), fetch="one")

def get_replies(tweet_id):
    """Retrieves threaded replies for a tweet."""
    return execute_query("SELECT * FROM get_replies(%s)", (tweet_id,), fetch="all")

def toggle_follow(source_user_id, target_user_id):
    """Toggles follow status between two users."""
    res = execute_query("SELECT * FROM toggle_follow(%s, %s)", (source_user_id, target_user_id), fetch="one")
    return res['toggle_follow'] if res and 'toggle_follow' in res else False

def get_followers(user_id):
    """Lists users who follow the given user."""
    return execute_query("SELECT * FROM get_followers(%s)", (user_id,), fetch="all")

def get_following(user_id):
    """Lists users that the given user follows."""
    return execute_query("SELECT * FROM get_following(%s)", (user_id,), fetch="all")

def send_message(sender_id, receiver_id, content):
    """Sends a direct message."""
    return execute_query("SELECT * FROM send_message(%s, %s, %s)", (sender_id, receiver_id, content), fetch="one")

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
    return execute_query("SELECT * FROM resolve_report_delete(%s, %s)", (report_id, admin_id), fetch="none")

def resolve_report_dismiss(report_id, admin_id):
    """Dismisses moderation report safely."""
    return execute_query("SELECT * FROM resolve_report_dismiss(%s, %s)", (report_id, admin_id), fetch="none")

def create_report(reporter_id, target_type, target_id, reason):
    """Submits a new moderation report."""
    return execute_query("SELECT * FROM create_report(%s, %s, %s, %s)", (reporter_id, target_type, target_id, reason), fetch="none")

def generate_user_report(user_id):
    """Computes comprehensive activity totals for a user."""
    return execute_query("SELECT * FROM generate_user_report(%s)", (user_id,), fetch="one")

def admin_bulk_dismiss(days_old, admin_id):
    """Dismisses old reports automatically."""
    return execute_query("SELECT * FROM admin_bulk_dismiss(%s, %s)", (days_old, admin_id), fetch="one")

def build_home_digest(user_id):
    """Creates a text digest of latest timeline tweets."""
    return execute_query("SELECT * FROM build_home_digest(%s)", (user_id,), fetch="one")
