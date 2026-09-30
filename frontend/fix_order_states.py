with open('src/Order.tsx', 'r') as f:
    text = f.read()

text = text.replace("SEARCHING", "PUBLISHED")
text = text.replace("AWAITING_DEPARTURE", "ASSIGNED")
text = text.replace("AT_PICKUP", "ARRIVED")
text = text.replace("execute('apply',", "execute('take',")
text = text.replace("order.my_offer?", "false?")

with open('src/Order.tsx', 'w') as f:
    f.write(text)
