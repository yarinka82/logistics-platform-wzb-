from dataclasses import dataclass

@dataclass
class Document:
    id: str
    purpose: str
    mime_type: str