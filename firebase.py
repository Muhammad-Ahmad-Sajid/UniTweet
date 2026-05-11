import firebase_admin
from firebase_admin import credentials, firestore
import base64
import datetime

FIREBASE_CREDENTIALS_PATH = "serviceAccountKey.json"

_db = None

def get_db():
    """
    Helper function to initialize and return the Firestore client.
    Ensures that the app is only initialized once.
    """
    global _db
    if _db is not None:
        return _db
    try:
        cred = credentials.Certificate(FIREBASE_CREDENTIALS_PATH)
        # Check if already initialized to avoid ValueError
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred)
        _db = firestore.client()
        return _db
    except Exception as e:
        print(f"Error initializing Firebase: {e}")
        return None

def test_firebase_connection():
    """
    Tests the connection to Firebase Firestore.
    Prints a success or failure message and returns True/False.
    """
    try:
        db = get_db()
        if db is not None:
            print("Firebase Connected Successfully")
            return True
        else:
            print("Firebase Connection Failed")
            return False
    except Exception as e:
        print(f"Error testing Firebase connection: {e}")
        return False

def sync_user_to_firebase(user_dict):
    """
    Saves or updates a user document in the 'users' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        reg_no = user_dict.get('reg_no')
        if not reg_no:
            print("Error: user_dict must contain 'reg_no' to use as document ID.")
            return False
            
        db.collection('users').document(str(reg_no)).set(user_dict)
        return True
    except Exception as e:
        print(f"Error syncing user to Firebase: {e}")
        return False

def get_user_from_firebase(reg_no):
    """
    Fetches a user document by reg_no from the 'users' collection.
    Returns the user dict on success, None on failure or if not found.
    """
    try:
        db = get_db()
        if not db:
            return None
            
        doc_ref = db.collection('users').document(str(reg_no))
        doc = doc_ref.get()
        if doc.exists:
            return doc.to_dict()
        return None
    except Exception as e:
        print(f"Error fetching user from Firebase: {e}")
        return None

def sync_tweet_to_firebase(tweet_dict):
    """
    Saves a tweet document in the 'tweets' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        tweet_id = tweet_dict.get('tweet_id')
        if tweet_id is not None:
            db.collection('tweets').document(str(tweet_id)).set(tweet_dict)
        else:
            db.collection('tweets').add(tweet_dict)
        return True
    except Exception as e:
        print(f"Error syncing tweet to Firebase: {e}")
        return False

def get_tweets_from_firebase(user_id):
    """
    Fetches all tweets by a user from the 'tweets' collection.
    Returns a list of tweet dicts on success, None on failure.
    """
    try:
        db = get_db()
        if not db:
            return None
            
        docs = db.collection('tweets').where('author_reg_no', '==', user_id).stream()
        tweets = [doc.to_dict() for doc in docs]
        return tweets
    except Exception as e:
        print(f"Error fetching tweets from Firebase: {e}")
        return None

def delete_tweet_from_firebase(tweet_id):
    """
    Soft deletes a tweet in Firestore by setting an 'is_deleted' flag.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        db.collection('tweets').document(str(tweet_id)).update({'is_deleted': True})
        return True
    except Exception as e:
        print(f"Error soft deleting tweet from Firebase: {e}")
        return False

def sync_follow_to_firebase(follower_id, followee_id):
    """
    Saves a follow relationship in the 'follows' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        follow_dict = {
            'follower_reg_no': follower_id,
            'following_reg_no': followee_id,
            'created_at': firestore.SERVER_TIMESTAMP
        }
        # Using a composite key for the document ID to prevent duplicate follow records
        doc_id = f"{follower_id}_{followee_id}"
        db.collection('follows').document(doc_id).set(follow_dict)
        return True
    except Exception as e:
        print(f"Error syncing follow to Firebase: {e}")
        return False

def sync_message_to_firebase(message_dict):
    """
    Saves a message in the 'direct_messages' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        message_id = message_dict.get('message_id')
        if message_id is not None:
            db.collection('direct_messages').document(str(message_id)).set(message_dict)
        else:
            db.collection('direct_messages').add(message_dict)
        return True
    except Exception as e:
        print(f"Error syncing message to Firebase: {e}")
        return False

def sync_report_to_firebase(report_dict):
    """
    Saves a report in the 'reports' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        report_id = report_dict.get('report_id')
        if report_id is not None:
            db.collection('reports').document(str(report_id)).set(report_dict)
        else:
            db.collection('reports').add(report_dict)
        return True
    except Exception as e:
        print(f"Error syncing report to Firebase: {e}")
        return False

def sync_like_to_firebase(like_dict):
    """
    Saves a like in the 'likes' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        tweet_id = like_dict.get('tweet_id')
        user_reg_no = like_dict.get('user_reg_no')
        
        # Use composite key if possible to easily toggle off later
        if tweet_id is not None and user_reg_no is not None:
            doc_id = f"{tweet_id}_{user_reg_no}"
            db.collection('likes').document(doc_id).set(like_dict)
        elif like_dict.get('like_id') is not None:
            db.collection('likes').document(str(like_dict.get('like_id'))).set(like_dict)
        else:
            db.collection('likes').add(like_dict)
        return True
    except Exception as e:
        print(f"Error syncing like to Firebase: {e}")
        return False

def sync_reply_to_firebase(reply_dict):
    """
    Saves a reply in the 'replies' collection.
    Returns True on success, False on failure.
    """
    try:
        db = get_db()
        if not db:
            return False
            
        reply_id = reply_dict.get('reply_id')
        if reply_id is not None:
            db.collection('replies').document(str(reply_id)).set(reply_dict)
        else:
            db.collection('replies').add(reply_dict)
        return True
    except Exception as e:
        print(f"Error syncing reply to Firebase: {e}")
        return False

def upload_avatar_to_firebase(user_id, image_bytes, filename):
    """Saves user avatar as base64 in Firestore."""
    try:
        db = get_db()
        if not db: return False
        
        image_base64 = base64.b64encode(image_bytes).decode('utf-8')
        doc_data = {
            'user_id': user_id,
            'filename': filename,
            'image_base64': image_base64,
            'uploaded_at': firestore.SERVER_TIMESTAMP
        }
        db.collection('user_avatars').document(str(user_id)).set(doc_data)
        return True
    except Exception as e:
        print(f"Error uploading avatar to Firebase: {e}")
        return False

def get_avatar_from_firebase(user_id):
    """Fetches user avatar from Firestore."""
    try:
        db = get_db()
        if not db: return None
        
        doc = db.collection('user_avatars').document(str(user_id)).get()
        if doc.exists:
            return doc.to_dict().get('image_base64')
        return None
    except Exception as e:
        print(f"Error fetching avatar from Firebase: {e}")
        return None

def upload_tweet_image_to_firebase(tweet_id, user_id, image_bytes, filename):
    """Saves tweet image as base64 in Firestore."""
    try:
        db = get_db()
        if not db: return False
        
        image_base64 = base64.b64encode(image_bytes).decode('utf-8')
        doc_data = {
            'tweet_id': tweet_id,
            'user_id': user_id,
            'filename': filename,
            'image_base64': image_base64,
            'uploaded_at': firestore.SERVER_TIMESTAMP
        }
        db.collection('tweet_images').document(str(tweet_id)).set(doc_data)
        return True
    except Exception as e:
        print(f"Error uploading tweet image to Firebase: {e}")
        return False

def get_tweet_image_from_firebase(tweet_id):
    """Fetches tweet image from Firestore."""
    try:
        db = get_db()
        if not db: return None
        
        doc = db.collection('tweet_images').document(str(tweet_id)).get()
        if doc.exists:
            return doc.to_dict().get('image_base64')
        return None
    except Exception as e:
        print(f"Error fetching tweet image from Firebase: {e}")
        return None

def delete_tweet_image_from_firebase(tweet_id):
    """Deletes tweet image document from Firestore."""
    try:
        db = get_db()
        if not db: return False
        
        db.collection('tweet_images').document(str(tweet_id)).delete()
        return True
    except Exception as e:
        print(f"Error deleting tweet image from Firebase: {e}")
        return False
