import os
from dotenv import load_dotenv
from anthropic import Anthropic

load_dotenv()
client = Anthropic(api_key=os.environ["LLM_API_KEY"])   # your key from .env

resp = client.messages.create(
    model="claude-haiku-4-5-20251001",   # cheap, fast model for bulk extraction
    max_tokens=100,
    messages=[{"role": "user", "content": "Reply with exactly: Claude is connected."}],
)
print(resp.content[0].text)