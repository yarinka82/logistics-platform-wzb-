with open('src/styles.css', 'r') as f:
    text = f.read()

text = text.replace(".status.SEARCHING", ".status.PUBLISHED")
text = text.replace(".status.AWAITING_DEPARTURE", ".status.ASSIGNED")
text = text.replace(".status.AT_PICKUP", ".status.ARRIVED")

with open('src/styles.css', 'w') as f:
    f.write(text)
